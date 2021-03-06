module Sisy.BuiltIn.Behaviours.FiresBullets where

import Prelude
import Data.Exists (Exists, mkExists)
import Data.Symbol (SProxy(..))
import Data.Variant (Variant, default, inj, onMatch)
import Sisy.Runtime.Behaviour as B
import Sisy.Runtime.Entity (EntityBehaviour(..), EntityId)
import Sisy.Math (Point, rotationToVector, scalePoint)
import Sisy.Types (Empty)
import Sisy.BuiltIn (BulletFired, bulletFired)

init ::
  forall entity cmd ev.
  { max :: Int, coolOffPeriod :: Int, speed :: Number, rate :: Int, power :: Number } ->
  Exists (EntityBehaviour (Command cmd) (Event ev) entity)
init { max, speed, coolOffPeriod, rate, power } =
  mkExists
    $ EntityBehaviour
        { state:
            { firingTimer: 0
            , coolOffTimer: 0
            , bulletsFired: 0
            , power
            , firing: false
            }
        , handleCommand: handleCommand
        }
  where
  handleCommand command state@{ firingTimer } = do
    entity <- B.entity
    onMatch
      { startFireBullet:
          \_ ->
            if state.coolOffTimer <= 0 then
              pure $ state { firing = true }
            else
              pure state
      , stopFireBullet:
          \_ ->
            if state.firing then
              pure $ state { firing = false, coolOffTimer = coolOffPeriod, firingTimer = 0, bulletsFired = 0 }
            else
              pure state
      , tick:
          \_ -> do
            if firingTimer <= 0 && state.firing && state.bulletsFired < max then do
              B.raiseEvent $ (bulletFired { owner: entity.id, location: location entity, velocity: velocity entity, power })
              pure $ state { firingTimer = rate, bulletsFired = state.bulletsFired + 1 }
            else if state.firing then
              pure $ state { firingTimer = state.firingTimer - 1 }
            else if (not state.firing) && state.coolOffTimer > 0 then
              pure $ state { coolOffTimer = state.coolOffTimer - 1 }
            else
              pure state
      }
      (default (pure state))
      command
    where
    direction entity = rotationToVector entity.rotation

    location entity = entity.location + (scalePoint 25.0 $ direction entity) -- tod: parameterise this starting distance

    velocity entity = (scalePoint speed $ direction entity) -- + entity.velocity

type Command cmd
  = ( startFireBullet :: Empty
    , stopFireBullet :: Empty
    | cmd
    )

type Event ev
  = ( bulletFired :: BulletFired
    | ev
    )
