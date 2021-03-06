module Blatus.Server.Web
  ( startLink
  , init
  , serverName
  , State
  ) where

import Prelude
import Control.Apply (lift3, lift2)
import Data.Either (either)
import Data.Map (fromFoldable)
import Data.Map as Map
import Data.Maybe (Maybe(..), fromMaybe, isJust)
import Data.Newtype (unwrap)
import Data.Tuple (Tuple(..))
import Effect (Effect)
import Erl.Atom (atom)
import Erl.Cowboy.Handlers.WebSocket (Frame(..))
import Erl.Cowboy.Req (CookieOpts, ReadUrlEncodedBodyResult(..), Req, StatusCode(..), parseCookies, readUrlEncodedBody, replyWithoutBody, setBody, setCookieWithOpts)
import Erl.Data.List (List, nil, (:))
import Erl.Data.Map as ErlMap
import Erl.Data.Tuple (Tuple2, tuple2, uncurry2)
import Erl.Process (send)
import Pinto (RegistryName(..), StartLinkResult)
import Pinto.GenServer (InitFn, InitResult(..), ServerPid, ServerType)
import Pinto.GenServer as Gen
import Blatus.Api (RunningGame)
import Blatus.Comms as Comms
import Blatus.Server.Logging as Log
import Blatus.Server.RunningGame as RunningGame
import Blatus.Server.RunningGameList as PureRunningGameList
import Blatus.ServerRoutes as ServerRoutes
import Simple.JSON (class WriteForeign, readJSON, writeJSON)
import SimpleBus as Bus
import Stetson (RestResult, StaticAssetLocation(..), StetsonHandler, SimpleStetsonHandler, WebSocketCallResult(..))
import Stetson as Stetson
import Stetson.Rest as Rest
import Stetson.WebSocket as WebSocket

newtype State
  = State {}

type PureWebStartArgs
  = { webPort :: Int }

serverName :: RegistryName (ServerType Unit Unit Unit State)
serverName = Local $ atom "web"

startLink :: PureWebStartArgs -> Effect (StartLinkResult (ServerPid Unit Unit Unit State))
startLink args = Gen.startLink $ (Gen.defaultSpec $ init args) { name = Just serverName }

init :: PureWebStartArgs -> InitFn Unit Unit Unit State
init { webPort } =
  Gen.lift
    $ do
        Log.info Log.Web "Starting up web server" { webPort }
        _ <-
          Stetson.configure
            # Stetson.routes
                ServerRoutes.topRoute
                { "Assets": PrivDir "blatus" "www/assets"
                , "Art": PrivDir "blatus" "www/art"
                , "GameStart": gamesHandler
                , "GameJoin": gameJoinHandler
                , "GameJoinHtml": (\(id :: String) -> PrivFile "blatus" "www/join.html")
                , "GamePlay": PrivFile "blatus" "www/game.html"
                , "GameComms": gameCommsHandler
                , "Index": PrivFile "blatus" "www/index.html"
                }
            # Stetson.port webPort
            # Stetson.bindTo 0 0 0 0
            # Stetson.startClear "http_listener"
        pure $ InitOk $ State {}

type GameCommsState
  = { game :: String
    , playerName :: String
    }

data GameCommsMsg
  = ProxiedServerMessage Comms.ServerMsg

gameCommsHandler :: StetsonHandler GameCommsMsg GameCommsState
gameCommsHandler =
  WebSocket.handler
    ( \req -> do
        let
          cookies = fromFoldable $ map (uncurry2 Tuple) $ parseCookies req
        Log.info Log.Web "cookies" { cookies }
        fromMaybe (WebSocket.initResult req { game: "", playerName: "" })
          $ lift2
              ( \playerName gameName -> do
                  _ <- RunningGame.addPlayer gameName playerName
                  Log.info Log.Web "Player connected" { playerName, gameName }
                  WebSocket.initResult req { game: gameName, playerName }
              )
              (Map.lookup "player-name" cookies)
              (Map.lookup "game-name" cookies)
    )
    # WebSocket.init
        ( \s -> do
            self <- WebSocket.self
            _ <- WebSocket.lift $ Bus.subscribe (RunningGame.bus s.game) $ ProxiedServerMessage >>> send self
            pure
              $ Reply
                  ( ( TextFrame
                        $ writeJSON
                            { gameUrl: ServerRoutes.routeUrl $ ServerRoutes.GameJoinHtml s.game
                            , playerId: s.playerName
                            }
                    )
                      : nil
                  )
                  s
        )
    # WebSocket.terminate
        ( \_ req s -> do
            -- actually need to do nothing here
            -- player will timeout anyway
            pure unit
        )
    # WebSocket.handle
        ( \msg state -> do
            case msg of
              TextFrame str ->
                Gen.lift do
                  either
                    ( \err -> do
                        Log.info Log.Web "Sent unintelligable command  from client" { err }
                        pure $ NoReply state
                    )
                    ( \cmd ->
                        RunningGame.sendCommand state.game state.playerName cmd
                          >>= case _ of
                              Nothing -> pure $ NoReply state
                              Just reply -> pure $ Reply ((TextFrame $ writeJSON $ reply) : nil) state
                    )
                    $ readJSON str
              other -> do
                _ <- Gen.lift $ Log.info Log.Web "Non text frame sent from client" { other }
                pure $ NoReply state
        )
    # WebSocket.info \msg state -> case msg of
        ProxiedServerMessage m@(Comms.PlayerSync { id }) -> do
          if (unwrap id) == state.playerName then
            pure $ Reply ((TextFrame $ writeJSON m) : nil) state
          else
            pure $ NoReply state
        ProxiedServerMessage m -> do
          --        _ <- Gen.lift $ Log.info Log.Web "Sending message" { m }
          pure $ Reply ((TextFrame $ writeJSON m) : nil) state

gamesHandler :: SimpleStetsonHandler (List RunningGame)
gamesHandler =
  Rest.handler
    ( \req -> do
        all <- PureRunningGameList.findPublic
        Rest.initResult req all
    )
    # Rest.allowedMethods (\req state -> Rest.result (Stetson.POST : Stetson.HEAD : Stetson.GET : Stetson.OPTIONS : nil) req state)
    # Rest.contentTypesProvided (\req state -> Rest.result (jsonWriter : nil) req state)
    # Rest.contentTypesAccepted (\req state -> Rest.result ((tuple2 "application/x-www-form-urlencoded" acceptForm) : nil) req state)
  where
  acceptForm =
    ( \req state -> do
        UrlEncodedBody kvs req2 <- readUrlEncodedBody req
        let
          processed = fromFoldable $ map (uncurry2 Tuple) kvs
        fromMaybe (Rest.result false (setBody "unable to comply" req) state)
          $ lift3
              ( \playerName gameName public -> do
                  Log.info Log.Web "Attempt to create game" { playerName, gameName, public }
                  gameId <- PureRunningGameList.create playerName gameName (public == "on")
                  ir <-
                    replyWithoutBody (StatusCode 302) (ErlMap.fromFoldable [ (Tuple "Location" $ ServerRoutes.routeUrl ServerRoutes.GamePlay) ])
                      $ setCookieWithOpts "game-name" gameId cookieOpts
                      $ setCookieWithOpts "player-name" playerName cookieOpts req
                  Rest.stop ir state
              )
              (Map.lookup "player-name" processed)
              (Map.lookup "game-name" processed)
              (Map.lookup "public" processed)
    )

gameJoinHandler :: String -> SimpleStetsonHandler (Maybe RunningGame)
gameJoinHandler gameId =
  Rest.handler
    ( \req -> do
        maybeGame <- PureRunningGameList.findById gameId
        Rest.initResult req maybeGame
    )
    # Rest.allowedMethods (\req state -> Rest.result (Stetson.POST : Stetson.HEAD : Stetson.GET : Stetson.OPTIONS : nil) req state)
    # Rest.resourceExists (\req state -> Rest.result (isJust state) req state)
    # Rest.contentTypesProvided (\req state -> Rest.result (jsonWriter : nil) req state)
    # Rest.contentTypesAccepted (\req state -> Rest.result ((tuple2 "application/x-www-form-urlencoded" acceptForm) : nil) req state)
  where
  acceptForm =
    ( \req state -> do
        UrlEncodedBody kvs req2 <- readUrlEncodedBody req
        let
          processed = fromFoldable $ map (uncurry2 Tuple) kvs
        fromMaybe (Rest.result false (setBody "unable to comply" req) state)
          $ ( \playerName -> do
                Log.info Log.Web "Attempt to join game" { gameId, playerName }
                ir <-
                  replyWithoutBody (StatusCode 302) (ErlMap.fromFoldable [ (Tuple "Location" $ ServerRoutes.routeUrl ServerRoutes.GamePlay) ])
                    $ setCookieWithOpts "game-name" gameId cookieOpts
                    $ setCookieWithOpts "player-name" playerName cookieOpts req
                Rest.stop ir state
            )
          <$> (Map.lookup "player-name" processed)
    )

cookieOpts :: CookieOpts
cookieOpts =
  { max_age: 3600
  , domain: ""
  , path: "/"
  , secure: false
  , http_only: false
  , same_site: (atom "strict")
  }

jsonWriter :: forall a. WriteForeign a => Tuple2 String (Req -> a -> (Effect (RestResult String a)))
jsonWriter = tuple2 "application/json" (\req state -> Rest.result (writeJSON state) req state)
