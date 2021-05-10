module Pure.Main where

import Prelude
import Blatus.Client.Assets (AssetPackage)
import Blatus.Client.Assets (AssetPackage, load) as Assets
import Blatus.Client.Background as Background
import Blatus.Client.Camera (Camera, CameraConfiguration, CameraViewport, applyViewport, setupCamera, viewportFromConfig)
import Blatus.Client.Camera as Camera
import Blatus.Comms (ClientMsg(..), ServerMsg(..))
import Blatus.Entities.Tank as Tank
import Blatus.Main as Main
import Blatus.Types (EntityCommand, GameEvent, GameEntity)
import Control.Monad.Except (runExcept)
import Data.DateTime.Instant as Instant
import Data.Either (either, hush)
import Data.Foldable (foldl, for_)
import Data.Int as Int
import Data.Map (lookup) as Map
import Data.Maybe (Maybe(..), fromMaybe, maybe, maybe')
import Data.Newtype (unwrap, wrap)
import Data.Symbol (SProxy(..))
import Data.Time.Duration (Milliseconds(..))
import Data.Traversable (for, traverse)
import Data.Tuple (fst)
import Data.Variant (Variant, expand, inj)
import Debug (spy)
import Effect (Effect)
import Effect.Aff (runAff_)
import Effect.Now as Now
import Foreign (readString)
import Graphics.Canvas as Canvas
import Math (abs)
import Math as Math
import Signal (Signal, dropRepeats, foldp, runSignal, sampleOn)
import Signal as Signal
import Signal.Channel as Channel
import Signal.DOM (keyPressed, animationFrame)
import Signal.Time (every, second)
import Simple.JSON (readJSON, writeJSON)
import Sisy.BuiltIn.Extensions.Bullets as Bullets
import Sisy.BuiltIn.Extensions.Explosions as Explosions
import Sisy.Runtime.Scene (Game, entityById)
import Sisy.Types (empty)
import Sisy.Math (Rect)
import Web.DOM.Document as Document
import Web.DOM.Element as Element
import Web.DOM.Node as Node
import Web.DOM.NodeList as NodeList
import Web.DOM.ParentNode (QuerySelector(..), querySelector)
import Web.Event.EventTarget as EET
import Web.Event.EventTarget as ET
import Web.HTML as HTML
import Web.HTML.Event.EventTypes as ETS
import Web.HTML.HTMLDocument as HTMLDocument
import Web.HTML.Location as Location
import Web.HTML.Window as Window
import Web.Socket.Event.EventTypes as WSET
import Web.Socket.Event.MessageEvent as ME
import Web.Socket.ReadyState as RS
import Web.Socket.WebSocket as WS

-- A pile of this is going to end up in Game.Main..
type LocalContext
  = { renderContext :: Canvas.Context2D
    , canvasElement :: Canvas.CanvasElement
    , offscreenContext :: Canvas.Context2D
    , offscreenCanvas :: Canvas.CanvasElement
    , assets :: Assets.AssetPackage
    , camera :: Camera
    , window :: HTML.Window
    , game :: Main.State
    , playerName :: String
    , socketChannel :: Channel.Channel String
    , socket :: WS.WebSocket
    , serverTick :: Int
    , tickLatency :: Int
    , gameUrl :: String
    , isStarted :: Boolean
    , hasError :: Boolean
    , now :: Number
    , sf1 :: Background.State
    , sf2 :: Background.State
    , sf3 :: Background.State
    }

rotateLeftSignal :: Effect (Signal (Variant EntityCommand))
rotateLeftSignal = do
  key <- keyPressed 37
  pure $ dropRepeats $ (\x -> if x then (inj (SProxy :: SProxy "turnLeft") empty) else (inj (SProxy :: SProxy "stopTurnLeft") empty)) <$> key

thrustSignal :: Effect (Signal (Variant EntityCommand))
thrustSignal = do
  key <- keyPressed 38
  pure $ dropRepeats $ (\x -> if x then (inj (SProxy :: SProxy "pushForward") empty) else (inj (SProxy :: SProxy "stopPushForward") empty)) <$> key

rotateRightSignal :: Effect (Signal (Variant EntityCommand))
rotateRightSignal = do
  key <- keyPressed 39
  pure $ dropRepeats $ (\x -> if x then (inj (SProxy :: SProxy "turnRight") empty) else (inj (SProxy :: SProxy "stopTurnRight") empty)) <$> key

brakeSignal :: Effect (Signal (Variant EntityCommand))
brakeSignal = do
  key <- keyPressed 40
  pure $ dropRepeats $ (\x -> if x then (inj (SProxy :: SProxy "pushBackward") empty) else (inj (SProxy :: SProxy "stopPushBackward") empty)) <$> key

fireSignal :: Effect (Signal (Variant EntityCommand))
fireSignal = do
  key <- keyPressed 32
  pure $ dropRepeats $ (\x -> if x then (inj (SProxy :: SProxy "startFireBullet") empty) else (inj (SProxy :: SProxy "stopFireBullet") empty)) <$> key

inputSignal :: Effect (Signal (Variant EntityCommand))
inputSignal = do
  fs <- fireSignal
  rl <- rotateLeftSignal
  ts <- thrustSignal
  rr <- rotateRightSignal
  bs <- brakeSignal
  pure $ fs <> rl <> ts <> rr <> bs

data GameLoopMsg
  = Input (Variant EntityCommand)
  | GameTick { time :: Number, hasError :: Boolean }
  | Ws String

tickSignal :: Signal Unit
tickSignal = sampleOn (every $ second / 30.0) $ Signal.constant unit

pingSignal :: Signal Unit
pingSignal = sampleOn (every $ second) $ Signal.constant unit

uiUpdateSignal :: Signal Unit
uiUpdateSignal = sampleOn (every $ second * 0.3) $ Signal.constant unit

load :: (LocalContext -> Effect Unit) -> Effect Unit
load cb = do
  runAff_
    ( \assets -> do
        maybeCanvas <- Canvas.getCanvasElementById "target"
        maybeOffscreen <- Canvas.getCanvasElementById "offscreen"
        fromMaybe (pure unit) $ prepareContexts <$> maybeCanvas <*> maybeOffscreen <*> (hush assets)
    )
    $ Assets.load
  where
  prepareContexts canvasElement offscreenCanvas assets = do
    window <- HTML.window
    location <- Window.location window
    renderContext <- Canvas.getContext2D canvasElement
    offscreenContext <- Canvas.getContext2D offscreenCanvas
    canvasWidth <- Canvas.getCanvasWidth canvasElement
    socketChannel <- Channel.channel $ ""
    host <- Location.host location
    socket <- createSocket ("ws://" <> host <> "/messaging") $ Channel.send socketChannel
    canvasHeight <- Canvas.getCanvasHeight canvasElement
    Milliseconds now <- Instant.unInstant <$> Now.now
    let
      camera = setupCamera { width: canvasWidth, height: canvasHeight }

      game = Main.init now
    sf1 <- Background.init 0.5 game.scene
    sf2 <- Background.init 0.3 game.scene
    sf3 <- Background.init 0.7 game.scene
    cb
      $ { offscreenContext
        , offscreenCanvas
        , renderContext
        , assets
        , canvasElement
        , camera
        , window
        , game
        , playerName: ""
        , gameUrl: ""
        , socket
        , socketChannel
        , serverTick: 0
        , now
        , tickLatency: 0
        , isStarted: false
        , hasError: false
        , sf1
        , sf2
        , sf3
        }

gameInfoSelector :: QuerySelector
gameInfoSelector = QuerySelector ("#game-info")

playerListSelector :: QuerySelector
playerListSelector = QuerySelector ("#player-list")

latencyInfoSelector :: QuerySelector
latencyInfoSelector = QuerySelector ("#latency-info")

gameMessageSelector :: QuerySelector
gameMessageSelector = QuerySelector ("#game-message")

healthSelector :: QuerySelector
healthSelector = QuerySelector ("#health")

shieldSelector :: QuerySelector
shieldSelector = QuerySelector ("#shield")

rockSelector :: QuerySelector
rockSelector = QuerySelector ("#rock")

quitSelector :: QuerySelector
quitSelector = QuerySelector ("#quit")

main :: Effect Unit
main = do
  load
    ( \loadedContext@{ socket, window } -> do
        gameInput <- inputSignal
        renderSignal <- animationFrame
        document <- HTMLDocument.toDocument <$> Window.document window
        location <- Window.location window
        Milliseconds start <- Instant.unInstant <$> Now.now
        ticksChannel <- Channel.channel { time: start, hasError: false }
        quitChannel <- Channel.channel false
        quitListener <- ET.eventListener (\_ -> Channel.send quitChannel true)
        gameInfoElement <- querySelector gameInfoSelector $ Document.toParentNode document
        latencyInfoElement <- querySelector latencyInfoSelector $ Document.toParentNode document
        playerListElement <- querySelector playerListSelector $ Document.toParentNode document
        gameMessageElement <- querySelector gameMessageSelector $ Document.toParentNode document
        healthElement <- querySelector healthSelector $ Document.toParentNode document
        shieldElement <- querySelector shieldSelector $ Document.toParentNode document
        rockElement <- querySelector rockSelector $ Document.toParentNode document
        quitElement <- querySelector quitSelector $ Document.toParentNode document
        -- Just alter context state as messages come in
        let
          socketSignal = Channel.subscribe loadedContext.socketChannel

          gameTickSignal = GameTick <$> Channel.subscribe ticksChannel

          quitSignal = Channel.subscribe quitChannel
        let
          gameStateSignal =
            foldp
              ( \msg lc -> case msg of
                  Input i -> handleClientCommand lc i
                  GameTick tick -> handleTick (lc { hasError = tick.hasError }) tick.time
                  Ws str -> either (handleServerError lc) (handleServerMessage lc) $ readJSON str
              )
              loadedContext
              $ gameTickSignal
              <> (Input <$> gameInput)
              <> (Ws <$> socketSignal)
        -- Feed the current time into the game state in a regulated manner
        -- Could probably do this whole thing with Signal.now and Signal.every
        -- if Signal.now wasn't arbitrary
        -- Once I refactor that massive LocalContext object I probably can as I won't need to init up front
        runSignal
          $ ( \_ -> do
                Milliseconds now <- Instant.unInstant <$> Now.now
                socketState <- WS.readyState socket
                Channel.send ticksChannel { time: now, hasError: socketState == RS.Closing || socketState == RS.Closed }
            )
          <$> tickSignal
        -- Send player input up to the server
        runSignal $ (\cmd -> safeSend socket $ writeJSON $ ClientCommand cmd) <$> gameInput
        -- Handle quitting manually
        runSignal
          $ ( \quit ->
                if quit then do
                  _ <- safeSend socket $ writeJSON Quit
                  _ <- Location.setHref "/" location
                  pure unit
                else
                  pure unit
            )
          <$> quitSignal
        maybe (pure unit) (\element -> ET.addEventListener ETS.click quitListener true $ Element.toEventTarget element) quitElement
        -- Tick as well
        runSignal
          $ ( \lc -> do
                -- Update the display
                _ <-
                  maybe (pure unit)
                    ( \element -> do
                        Element.setAttribute "href" lc.gameUrl element
                        Node.setTextContent lc.gameUrl $ Element.toNode element
                    )
                    gameInfoElement
                _ <-
                  maybe (pure unit)
                    ( \element -> do
                        if lc.hasError then
                          Node.setTextContent "Error: Not connected" $ Element.toNode element
                        else
                          Node.setTextContent ("Connected (" <> (show (lc.tickLatency * 33)) <> "ms)") $ Element.toNode element
                    )
                    latencyInfoElement
                _ <-
                  maybe (pure unit)
                    ( \element ->
                        if lc.hasError then
                          Node.setTextContent "Server disconnected, try refreshing or switch games" $ Element.toNode element
                        else case Main.pendingSpawn (wrap lc.playerName) lc.game of
                          Nothing -> Node.setTextContent "" $ Element.toNode element
                          Just ticks -> Node.setTextContent ("Waiting " <> (show (ticks `div` 30)) <> " seconds to respawn") $ Element.toNode element
                    )
                    gameMessageElement
                _ <-
                  maybe (pure unit)
                    ( \element ->
                        maybe (pure unit)
                          ( \player -> do
                              let
                                percentage = show $ (player.health / Tank.maxHealth) * 100.0
                              Node.setTextContent percentage $ Element.toNode element
                          )
                          $ entityById (wrap lc.playerName) lc.game.scene
                    )
                    healthElement
                _ <-
                  maybe (pure unit)
                    ( \element ->
                        maybe (pure unit)
                          ( \player -> do
                              let
                                percentage = show $ (player.shield / Tank.maxShield) * 100.0
                              Node.setTextContent percentage $ Element.toNode element
                          )
                          $ entityById (wrap lc.playerName) lc.game.scene
                    )
                    shieldElement
                _ <-
                  maybe (pure unit)
                    ( \element ->
                        maybe (pure unit)
                          ( \player -> do
                              let
                                amount = show $ player.availableRock
                              Node.setTextContent amount $ Element.toNode element
                          )
                          $ Map.lookup (wrap lc.playerName) lc.game.players
                    )
                    rockElement
                _ <-
                  maybe (pure unit)
                    ( \element -> do
                        let
                          node = Element.toNode element
                        existingChildren <- NodeList.toArray =<< Node.childNodes node
                        _ <- traverse (\child -> Node.removeChild child node) $ existingChildren
                        _ <-
                          traverse
                            ( \player -> do
                                li <- Element.toNode <$> Document.createElement "li" document
                                Node.setTextContent ((unwrap player.id) <> ": " <> (show player.score)) li
                                Node.appendChild li node
                            )
                            $ lc.game.players
                        pure unit
                    )
                    playerListElement
                pure unit
            )
          <$> sampleOn uiUpdateSignal gameStateSignal
        -- Tick
        runSignal $ (\lc -> safeSend socket $ writeJSON $ Ping lc.game.lastTick) <$> sampleOn pingSignal gameStateSignal
        -- Take whatever the latest state is and render it every time we get a render frame request
        runSignal $ render <$> sampleOn renderSignal gameStateSignal
    )

safeSend :: WS.WebSocket -> String -> Effect Unit
safeSend ws str = do
  state <- WS.readyState ws
  case state of
    RS.Open -> WS.sendString ws str
    _ -> pure unit

handleServerError :: forall a. LocalContext -> a -> LocalContext
handleServerError lc _ = lc { hasError = true }

handleServerMessage :: LocalContext -> ServerMsg -> LocalContext
handleServerMessage lc msg = case msg of
  Sync gameSync ->
    if not lc.isStarted then
      let
        newGame = Main.fromSync lc.now gameSync
      in
        lc
          { game = newGame
          , serverTick = gameSync.tick
          , isStarted = true
          }
    else
      let
        game = lc.game --Trace.trace { msg: "pre", game: lc.game } \_ -> lc.game

        updated = Main.mergeSyncInfo game gameSync -- Trace.trace {msg: "sync", sync: gameSync } \_ -> Main.mergeSyncInfo game gameSync

        result = lc { game = updated, serverTick = gameSync.tick } --Trace.trace {msg: "after", game: updated } \_ -> lc { game = updated, serverTick = gameSync.tick }
      in
        result
  PlayerSync sync -> lc { game = Main.mergePlayerSync lc.game sync }
  Welcome info -> lc { gameUrl = info.gameUrl, playerName = info.playerId }
  ServerCommand { id, cmd: cmd } ->
    if (unwrap id) == lc.playerName then
      lc
    else
      lc { game = fst $ Main.sendCommand id (expand cmd) lc.game }
  ServerEvents evs -> lc { game = foldl (\a i -> fst $ Main.handleEvent a i) lc.game evs }
  PlayerAdded id -> lc { game = Main.addPlayer id lc.game }
  PlayerRemoved id -> lc { game = Main.removePlayer id lc.game }
  Pong tick -> lc { tickLatency = lc.game.lastTick - tick }

handleClientCommand :: LocalContext -> Variant EntityCommand -> LocalContext
handleClientCommand lc@{ playerName, game } msg = lc { game = fst $ Main.sendCommand (wrap playerName) (expand msg) game }

handleTick :: LocalContext -> Number -> LocalContext
handleTick context@{ game, camera: { config }, playerName, socket } now =
  let
    newGame = fst $ Main.tick now game

    updatedConfig = trackPlayer playerName newGame.scene config

    viewport = viewportFromConfig updatedConfig

    updatedContext = context { camera = { config: updatedConfig, viewport } }
  in
    updatedContext { game = newGame, now = now }

trackPlayer :: String -> Game EntityCommand GameEvent GameEntity -> CameraConfiguration -> CameraConfiguration
trackPlayer playerName game config =
  maybe' (\_ -> config { distance = config.distance + 2.0 })
    ( \player ->
        let
          targetDistance = 750.0 + (abs player.velocity.x + abs player.velocity.y) * 20.0
        in
          config
            { lookAt = player.location
            , distance = config.distance + 0.02 * (targetDistance - config.distance)
            }
    )
    $ entityById (wrap playerName) game

render :: LocalContext -> Effect Unit
render context@{ camera: camera@{ viewport, config: { target: { width, height } } }, game, offscreenContext, offscreenCanvas, renderContext, assets, sf1, sf2, sf3 } = do
  _ <- Canvas.clearRect offscreenContext { x: 0.0, y: 0.0, width, height }
  _ <- Canvas.save offscreenContext
  _ <- applyViewport viewport offscreenContext
  _ <- Background.render camera sf1 offscreenContext
  _ <- Background.render camera sf2 offscreenContext
  _ <- Background.render camera sf3 offscreenContext
  _ <- renderExplosions game.explosions offscreenContext
  _ <- renderBullets game.bullets offscreenContext
  _ <- renderScene viewport game.scene assets offscreenContext
  _ <- Canvas.restore offscreenContext
  let
    image = Canvas.canvasElementToImageSource offscreenCanvas
  _ <- Canvas.clearRect renderContext { x: 0.0, y: 0.0, width, height }
  _ <- Canvas.drawImage renderContext image 0.0 0.0
  pure unit

prepareScene :: forall cmd ev entity. CameraViewport -> Game cmd ev entity -> Game cmd ev entity
prepareScene viewport game = game

renderExplosions :: Explosions.State -> Canvas.Context2D -> Effect Unit
renderExplosions state ctx = do
  _ <- Canvas.setFillStyle ctx "#0ff"
  _ <- Canvas.beginPath ctx
  _ <-
    traverse
      ( \b -> do
          let
            radius = (Int.toNumber b.age) + 2.0
          _ <- Canvas.moveTo ctx (b.location.x + radius) b.location.y
          _ <-
            Canvas.arc ctx
              { x: b.location.x
              , y: b.location.y
              , start: 0.0
              , end: (2.0 * Math.pi)
              , radius: radius
              }
          _ <- Canvas.fill ctx
          pure unit
      )
      state.explosions
  Canvas.fill ctx

renderBullets :: Bullets.State -> Canvas.Context2D -> Effect Unit
renderBullets state ctx = do
  _ <- Canvas.setFillStyle ctx "#0ff"
  _ <- Canvas.beginPath ctx
  _ <-
    traverse
      ( \b -> do
          _ <- Canvas.moveTo ctx (b.location.x + 2.5) b.location.y
          _ <-
            Canvas.arc ctx
              { x: b.location.x
              , y: b.location.y
              , start: 0.0
              , end: (2.0 * Math.pi)
              , radius: 2.5
              }
          _ <- Canvas.fill ctx
          pure unit
      )
      state.bullets
  Canvas.fill ctx

renderScene :: forall cmd ev entity. CameraViewport -> Game cmd ev ( aabb :: Rect | entity ) -> AssetPackage -> Canvas.Context2D -> Effect Unit
renderScene viewport { entities } assets ctx = do
  _ <-
    for entities \{ aabb, location, renderables, rotation } -> do
      if (Camera.testRect viewport aabb) then
        Canvas.withContext ctx
          $ do
              _ <- Canvas.translate ctx { translateX: location.x, translateY: location.y }
              _ <- Canvas.rotate ctx (rotation * 2.0 * Math.pi)
              _ <-
                for renderables \{ transform, color, image, rotation: rr, visible } ->
                  Canvas.withContext ctx
                    $ do
                        if visible then do
                          _ <- Canvas.translate ctx { translateX: transform.x, translateY: transform.y }
                          _ <- Canvas.rotate ctx (rr * 2.0 * Math.pi)
                          _ <- Canvas.translate ctx { translateX: (-transform.x), translateY: (-transform.y) }
                          _ <- Canvas.setFillStyle ctx (unwrap color)
                          _ <-
                            fromMaybe (Canvas.fillRect ctx transform)
                              $ map (\img -> Canvas.drawImageScale ctx img transform.x transform.y transform.width transform.height)
                              $ (flip Map.lookup assets)
                              =<< image
                          pure unit
                        else
                          pure unit
              Canvas.translate ctx { translateX: (-location.x), translateY: (-location.y) }
      else
        pure unit
  pure unit

createSocket :: String -> (String -> Effect Unit) -> Effect WS.WebSocket
createSocket url cb = do
  socket <- WS.create url []
  listener <-
    EET.eventListener \ev ->
      for_ (ME.fromEvent ev) \msgEvent ->
        for_ (runExcept $ readString $ ME.data_ msgEvent) cb
  EET.addEventListener WSET.onMessage listener false (WS.toEventTarget socket)
  pure socket

destroySocket :: WS.WebSocket -> Effect Unit
destroySocket socket = do
  _ <- WS.close socket
  pure unit
