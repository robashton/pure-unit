module Blatus.Entities.Asteroid where

import Prelude
import Data.List (List(..), (:))
import Sisy.BuiltIn.Behaviours.BasicBitchPhysics as BasicBitchPhysics
import Sisy.Runtime.Entity (Entity, EntityId, HtmlColor(..), sprite)
import Sisy.Math (Point)
import Blatus.Types (EntityCommand, GameEvent, GameEntity, EntityClass(..))

data EntityMode
  = Server
  | Client

init :: EntityId -> Point -> Number -> Number -> Entity EntityCommand GameEvent GameEntity
init id location width height =
  { id
  , location
  , width
  , height
  , velocity: { x: 0.0, y: 0.0 }
  , friction: 0.0
  , rotation: 0.0
  , mass: 200.0
  , health: 100.0
  , shield: 0.0
  , behaviour: Nil
  , class: Asteroid
  , networkSync: true
  , renderables:
      ( sprite
          { transform =
            { x: -(width / 2.0)
            , y: -(height / 2.0)
            , width
            , height
            }
          , color = HtmlColor "#ccc"
          }
      )
        : Nil
  }
