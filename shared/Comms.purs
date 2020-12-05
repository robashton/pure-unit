module Pure.Comms where

import Prelude
import Pure.Game (Game)
import Pure.Game as Game
import Pure.Entity (EntityId(..), Entity, EntityClass(..), EntityCommand(..), GameEvent)
import Data.List (toUnfoldable)
import Data.Maybe (maybe)
import Data.Foldable (foldl)
import Pure.Math (Point(..))
import Pure.Math as Math
import Control.Alt ((<|>))
import Data.Generic.Rep (class Generic)
import Data.Newtype (class Newtype, wrap)
import Data.Generic.Rep.Show (genericShow)
import Foreign (Foreign)
import Foreign as Foreign
import Data.Map as Map
import Simple.JSON (class ReadForeign, class WriteForeign, readImpl, writeImpl)
import GenericJSON (writeTaggedSumRep, taggedSumRep)
import Pure.Math (Rect)

data ServerMsg = Sync GameSync
               | NewEntity EntitySync
               | PlayerSync EntitySync
               | Welcome WelcomeInfo
               | ServerCommand { cmd :: EntityCommand, id  :: EntityId }
               | ServerEvents (Array GameEvent)
               | UpdatePlayerList (Array PlayerListItem)
               | EntityDeleted EntityId
               | Pong Int

type PlayerListItem = { playerId :: String
                      , score :: Int
                      , lastTick :: Int
                      }

data ClientMsg = ClientCommand EntityCommand
               | Ping Int

type WelcomeInfo = { gameUrl :: String
                   , playerId :: String
                   }

type GameSync = { world :: Rect
                , entities :: Array EntitySync
                , tick :: Int
                }

type EntitySync = { id :: EntityId
                  , class ::  EntityClass
                  , location :: Point
                  , velocity :: Point
                  , rotation :: Number
                  }


derive instance genericServerMsg :: Generic ServerMsg _
instance showServerMsg :: Show ServerMsg where
  show = genericShow
instance writeForeignServerMsg :: WriteForeign ServerMsg where
  writeImpl = writeTaggedSumRep
instance readForeignServerMsg :: ReadForeign ServerMsg where
  readImpl = taggedSumRep

derive instance genericClientMsg :: Generic ClientMsg _
instance showClientMsg :: Show ClientMsg where
  show = genericShow
instance writeForeignClientMsg :: WriteForeign ClientMsg where
  writeImpl = writeTaggedSumRep
instance readForeignClientMsg :: ReadForeign ClientMsg where
  readImpl = taggedSumRep

  
gameToSync :: Game -> Int -> GameSync
gameToSync { entities, world } tick =
  { entities: toUnfoldable $ map entityToSync $ Map.values entities
  , world
  , tick}

entityToSync :: Entity -> EntitySync
entityToSync { id, class: c, location, velocity, rotation } =
  { id, class: c, location, velocity, rotation }


gameFromSync :: GameSync -> Game
gameFromSync { entities, world } = {
  world,
  entities: foldl (\m e -> Map.insert e.id (entityFromSync e) m) mempty entities
  }

mergeSyncInfo :: Game -> GameSync -> Game
mergeSyncInfo game sync =
  foldl (\acc es -> Game.discardEvents $ Game.sendCommand es.id (UpdateServerState { location: es.location
                                                                  , velocity: es.velocity
                                                                  , rotation: es.rotation 
                                                                  }) acc
    ) game sync.entities


mergePlayerSync :: Game -> EntitySync -> Game
mergePlayerSync game es =
  Game.discardEvents $ Game.sendCommand es.id (UpdateServerState { location: es.location
                                            , velocity: es.velocity
                                            , rotation: es.rotation 
                                            }) game
                        

entityFromSync :: EntitySync -> Entity
entityFromSync sync =
  let blank = case sync.class of
                Tank -> Game.tank sync.id Game.Client sync.location
                Bullet -> Game.bullet sync.id sync.location sync.velocity
   in
   blank { location = sync.location
         , velocity = sync.velocity
         , rotation = sync.rotation }
