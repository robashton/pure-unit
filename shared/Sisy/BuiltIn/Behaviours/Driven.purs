module Sisy.BuiltIn.Behaviours.Driven where

import Prelude
import Data.Exists (Exists, mkExists)
import Data.Variant (default, onMatch)
import Sisy.Runtime.Behaviour as B
import Sisy.BuiltIn.Behaviours.BasicBitchPhysics as BasicBitchPhysics
import Sisy.Runtime.Entity (EntityBehaviour(..))
import Sisy.Types (Empty)

type DrivenConfig
  = { maxSpeed :: Number
    , acceleration :: Number
    , turningSpeed :: Number
    }

init ::
  forall entity cmd ev.
  DrivenConfig -> Exists (EntityBehaviour (Command cmd) ev (BasicBitchPhysics.Required entity))
init config =
  mkExists
    $ EntityBehaviour
        { state: { forward: false, backward: false, left: false, right: false }
        , handleCommand:
            \command s ->
              onMatch
                { tick:
                    \_ -> do
                      ( if s.forward then
                          BasicBitchPhysics.applyThrust config.acceleration config.maxSpeed
                        else if s.backward then
                          BasicBitchPhysics.applyThrust (-config.acceleration) config.maxSpeed
                        else
                          pure unit
                      )
                      ( if s.left then
                          B.rotate (-config.turningSpeed)
                        else if s.right then
                          B.rotate config.turningSpeed
                        else
                          pure unit
                      )
                      pure s
                , pushForward: \_ -> pure s { forward = true }
                , pushBackward: \_ -> pure s { backward = true }
                , turnLeft: \_ -> pure s { left = true }
                , turnRight: \_ -> pure s { right = true }
                , stopPushForward: \_ -> pure s { forward = false }
                , stopPushBackward: \_ -> pure s { backward = false }
                , stopTurnLeft: \_ -> pure s { left = false }
                , stopTurnRight: \_ -> pure s { right = false }
                }
                (default (pure s))
                command
        }

type Command r
  = ( pushForward :: Empty
    , pushBackward :: Empty
    , turnLeft :: Empty
    , turnRight :: Empty
    , stopPushForward :: Empty
    , stopPushBackward :: Empty
    , stopTurnLeft :: Empty
    , stopTurnRight :: Empty
    | r
    )
