module Sisy.BuiltIn.Behaviours.Damageable where

import Prelude
import Data.Exists (Exists, mkExists)
import Data.Variant (default, onMatch)
import Sisy.BuiltIn (Damage, EntityDestroyed, entityDestroyed)
import Sisy.Runtime.Behaviour as B
import Sisy.Runtime.Entity (EntityBehaviour(..))

init ::
  forall entity cmd ev.
  Exists (EntityBehaviour (Command cmd) (Event ev) (Required entity))
init =
  mkExists
    $ EntityBehaviour
        { state: { shieldVisible: true }
        , handleCommand:
            \command s ->
              onMatch
                { damage:
                    \damage -> do
                      entity <- B.entity
                      let
                        health = if entity.shield <= 0.0 then entity.health - damage.amount else entity.health

                        shield = if entity.shield > 0.0 then entity.shield - damage.amount else 0.0
                      B.updateEntity (\e -> e { health = health, shield = shield })
                      if health <= 0.0 then do
                        B.raiseEvent $ entityDestroyed { entity: entity.id, destroyer: damage.source }
                        pure s
                      else
                        pure s
                , tick:
                    \_ -> do
                      entity <- B.entity
                      if entity.shield <= 0.0 && s.shieldVisible then do
                        B.updateEntity \e -> e { renderables = map (\r -> if r.id == "shield" then r { visible = false } else r) e.renderables }
                        pure s { shieldVisible = false }
                      else if entity.shield > 0.0 && (not s.shieldVisible) then do
                        B.updateEntity \e -> e { renderables = map (\r -> if r.id == "shield" then r { visible = true } else r) e.renderables }
                        pure s { shieldVisible = true }
                      else
                        pure s
                }
                (default (pure s))
                command
        }

type Required r
  = ( health :: Number
    , shield :: Number
    | r
    )

type Command r
  = ( damage :: Damage
    | r
    )

type Event r
  = ( entityDestroyed :: EntityDestroyed
    | r
    )
