{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}

{- |
Module: Actors.Actor
Description: Actor system framework for the Time-Bandits architecture.

This module provides the Actor abstraction, which defines the interface for
actors in the Time Bandits system. Actors are responsible for:

- Submitting transition messages to the controller
- Receiving and processing responses
- Managing their own state and resources
- Communicating with other actors

The Actor abstraction is implemented differently depending on the simulation mode:
- In-memory: Actors are Haskell functions in the same process
- Local multi-process: Actors run in separate processes with Unix socket messaging
- Geo-distributed: Actors run on remote machines with TCP/RPC messaging

In the Time-Bandits architecture, Actors play several critical roles:

1. Autonomous agents: Actors encapsulate autonomous behavior, with each type
   (TimeTraveler, TimeKeeper, TimeBandit) having specific capabilities and responsibilities.

2. Security boundaries: Each actor maintains its own cryptographic identity and state,
   enabling secure, authenticated communications.

3. Distributed execution: Actors can be distributed across multiple machines,
   enabling robust, fault-tolerant execution of programs.

4. Resource management: Actors claim, transfer, and verify ownership of resources
   across timelines, enabling complex cross-timeline operations.

The Actor module connects with the Programs module for program execution,
the Execution module for effect handling, and the Core module for basic
primitives like cryptographic functions and event handling.
-}
module Actors.Actor 
  ( -- * Core Types
    Actor(..)
  , ActorSpec(..)
  , ActorRole(..)
  , ActorCapability(..)
  , ActorState(..)
  , ActorError(..)
  , ActorHandle
  
  -- * Actor Operations
  , createActor
  , runActor
  , sendMessage
  , receiveMessage
  , getActorId
  , getActorRole
  , getActorCapabilities
  
  -- * Deployment Operations
  , deployActor
  , deployInMemoryActor
  , deployLocalActor
  , deployRemoteActor
  
  -- * Actor Communication
  , ActorMessage(..)
  , MessageQueue
  , createMessageQueue
  , enqueueMessage
  , dequeueMessage
  ) where

import Control.Concurrent (ThreadId, forkIO, threadDelay)
import Control.Concurrent.Chan (Chan, newChan, readChan, writeChan)
import Control.Concurrent.MVar (MVar, newMVar, takeMVar, putMVar)
import Control.Monad (forever, void, when, replicateM)
import Data.ByteString (ByteString)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Serialize (Serialize)
import Data.Text (Text)
import qualified Data.Text as T
import GHC.Generics (Generic)
import Network.Socket (Socket, SockAddr(..), PortNumber)
import Polysemy (Member, Sem, Embed, embed, runM)
import Polysemy.Error (Error, throw, runError)
import System.Process (ProcessHandle)
import qualified Data.ByteString.Char8 as BS
import qualified Data.IORef as IORef
import System.Directory (createDirectoryIfMissing)
import Polysemy.Trace qualified as PT
import Adapters.NetworkQUIC (startQuicServer, p2pConfigToQuicConfig)
import Adapters.Network (P2PConfig(..))
import Data.Time.Clock (UTCTime, getCurrentTime)

-- Import from TimeBandits modules
import Core (ActorHash, Hash(..), EntityHash(..))
import Core.Types
  ( AppError(..)
  , LamportTime(..)
  , PubKey(..)
  , Actor(..)
  , ActorType(..)
  )
import Core.Resource 
  ( Resource(..)
  , ResourceId
  )
import Programs.Program 
  ( ProgramId
  )
import Actors.TransitionMessage
  ( TransitionMessage
  )
import Core.Common
  ( SimulationMode(..)
  )
import Actors.ActorTypes
  ( ActorType(..)
  , ActorRole(..)
  , ActorCapability(..)
  , ActorSpec(..)
  )

-- Import specialized actor role modules (forward references)
import qualified Actors.TimeTraveler as TimeTraveler
import qualified Actors.TimeKeeper as TimeKeeper
import qualified Actors.TimeBandit as TimeBandit
import qualified Actors.ActorCoordination as ActorCoordination

-- | The Actor handle for interaction with an actor
data ActorHandle r = ActorHandle
  { handleId :: Text
  , handleType :: ActorType
  , handleProcess :: Maybe ProcessHandle
  , handleThread :: Maybe ThreadId
  , handleSocket :: Maybe Socket
  , handleMailbox :: Chan TransitionMessage
  }

-- | Actor class defines the interface for all actors
class Actor a where
  -- | Run the actor
  runActor :: a -> IO ()
  
  -- | Get the actor's ID
  getActorId :: a -> Address
  
  -- | Get the actor's role
  getActorRole :: a -> ActorRole
  
  -- | Get the actor's capabilities
  getActorCapabilities :: a -> [ActorCapability]
  
  -- | Send a message to the actor
  sendMessage :: a -> ActorMessage -> IO ()
  
  -- | Receive a message from the actor
  receiveMessage :: a -> IO (Maybe ActorMessage)

-- | Create an actor from a specification
createActor :: (Member (Error AppError) r, Member (Error ActorError) r) => ActorSpec -> Sem r ActorState
createActor spec = do
  -- Create the initial actor state
  let state = ActorState
        { actorStateId = actorSpecId spec
        , actorStateRole = actorSpecRole spec
        , actorStateCapabilities = actorSpecCapabilities spec
        , actorStatePrograms = actorSpecInitialPrograms spec
        , actorStateResources = []
        }
  
  return state

-- | Deploy an actor in the specified mode
deployActor :: (Member (Error ActorError) r)
           => ActorSpec
           -> DeploymentMode
           -> Sem r (ActorHandle r)
deployActor spec mode = case mode of
  InMemory -> deployInMemoryActor spec
  LocalProcesses -> deployLocalActor spec
  GeoDistributed -> deployRemoteActor spec

-- | Deploy an actor in in-memory mode
deployInMemoryActor :: (Member (Error ActorError) r)
                   => ActorSpec
                   -> Sem r (ActorHandle r)
deployInMemoryActor spec = do
  -- Create a message queue for the actor
  messageQueue <- liftIO $ newTQueueIO
  
  -- For specialized actor roles, create the appropriate type
  case actorRole spec of
    TimeTravelerRole -> do
      -- Import the specialized TimeTraveler module
      import qualified Actors.TimeTraveler as TT
      
      -- Create a TimeTraveler spec from the actor spec
      let travelerSpec = TT.TimeTravelerSpec
            { TT.travelerId = actorId spec
            , TT.capabilities = actorCapabilities spec
            , TT.ownedResources = []
            , TT.programAccess = Map.empty
            , TT.timeMapAccess = True -- Default access
            }
      
      -- Create the TimeTraveler
      let traveler = TT.createTimeTraveler travelerSpec
      
      -- Create actor state with the specialized actor
      actorState <- liftIO $ newIORef $ ActorState
        { stateId = actorId spec
        , stateRole = actorRole spec
        , stateCapabilities = actorCapabilities spec
        , stateSpecializedActor = Just $ encodeSpecializedActor traveler
        , stateDeploymentMode = InMemory
        , stateMessageQueue = messageQueue
        }
      
      -- Create and return an actor handle
      return $ ActorHandle
        { runActor = runInMemoryActor actorState
        , getActorId = actorId spec
        , getActorRole = actorRole spec
        , getActorCapabilities = actorCapabilities spec
        , sendMessage = sendToInMemoryActor messageQueue
        , receiveMessage = receiveFromInMemoryActor messageQueue
        }
    
    TimeKeeperRole -> do
      -- Import the specialized TimeKeeper module
      import qualified Actors.TimeKeeper as TK
      
      -- Create a TimeKeeper spec from the actor spec
      let keeperSpec = TK.TimeKeeperSpec
            { TK.keeperSpecId = actorId spec
            , TK.keeperSpecTimelines = []  -- No timelines initially
            , TK.keeperSpecValidationRules = []  -- No rules initially
            }
      
      -- Create the TimeKeeper
      let keeper = TK.createTimeKeeper keeperSpec Map.empty
      
      -- Create actor state with the specialized actor
      actorState <- liftIO $ newIORef $ ActorState
        { stateId = actorId spec
        , stateRole = actorRole spec
        , stateCapabilities = actorCapabilities spec
        , stateSpecializedActor = Just $ encodeSpecializedActor keeper
        , stateDeploymentMode = InMemory
        , stateMessageQueue = messageQueue
        }
      
      -- Create and return an actor handle
      return $ ActorHandle
        { runActor = runInMemoryActor actorState
        , getActorId = actorId spec
        , getActorRole = actorRole spec
        , getActorCapabilities = actorCapabilities spec
        , sendMessage = sendToInMemoryActor messageQueue
        , receiveMessage = receiveFromInMemoryActor messageQueue
        }
    
    TimeBanditRole -> do
      -- Import the specialized TimeBandit module
      import qualified Actors.TimeBandit as TB
      
      -- Create a TimeBandit spec from the actor spec
      let banditSpec = TB.TimeBanditSpec
            { TB.banditSpecId = actorId spec
            , TB.banditSpecCapabilities = actorCapabilities spec
            , TB.banditSpecNetwork = "" -- Default network address
            , TB.banditSpecInitialPeers = []  -- No peers initially
            , TB.banditSpecInitialKeepers = Map.empty  -- No keepers initially
            }
      
      -- Create the TimeBandit
      let bandit = TB.createTimeBandit banditSpec
      
      -- Create actor state with the specialized actor
      actorState <- liftIO $ newIORef $ ActorState
        { stateId = actorId spec
        , stateRole = actorRole spec
        , stateCapabilities = actorCapabilities spec
        , stateSpecializedActor = Just $ encodeSpecializedActor bandit
        , stateDeploymentMode = InMemory
        , stateMessageQueue = messageQueue
        }
      
      -- Create and return an actor handle
      return $ ActorHandle
        { runActor = runInMemoryActor actorState
        , getActorId = actorId spec
        , getActorRole = actorRole spec
        , getActorCapabilities = actorCapabilities spec
        , sendMessage = sendToInMemoryActor messageQueue
        , receiveMessage = receiveFromInMemoryActor messageQueue
        }

-- | Helper function to encode specialized actor types
encodeSpecializedActor :: Serialize a => a -> ByteString
encodeSpecializedActor = encode

-- | Helper function to decode specialized actor types
decodeSpecializedActor :: Serialize a => ByteString -> Either String a
decodeSpecializedActor = decode

-- Make ActorHandle an instance of Actor
instance Actor ActorHandle where
  runActor handle = case handle of
    InMemoryHandle{} -> pure () -- Already running in its own thread
    LocalProcessHandle{} -> pure () -- Already running in its own process
    RemoteHandle{} -> pure () -- Already running on a remote machine
  
  getActorId handle = case handle of
    InMemoryHandle{inMemoryId} -> inMemoryId
    LocalProcessHandle{localProcessId} -> localProcessId
    RemoteHandle{remoteId} -> remoteId
  
  getActorRole handle = case handle of
    InMemoryHandle{inMemoryState} -> do
      state <- takeMVar inMemoryState
      let role = actorStateRole state
      putMVar inMemoryState state
      return role
    LocalProcessHandle{} -> Observer -- Default for now
    RemoteHandle{} -> Observer -- Default for now
  
  getActorCapabilities handle = case handle of
    InMemoryHandle{inMemoryState} -> do
      state <- takeMVar inMemoryState
      let capabilities = actorStateCapabilities state
      putMVar inMemoryState state
      return capabilities
    LocalProcessHandle{} -> [] -- Default for now
    RemoteHandle{} -> [] -- Default for now
  
  sendMessage handle msg = case handle of
    InMemoryHandle{inMemoryQueue} -> enqueueMessage inMemoryQueue msg
    LocalProcessHandle{} -> pure () -- Not implemented yet
    RemoteHandle{} -> pure () -- Not implemented yet
  
  receiveMessage handle = case handle of
    InMemoryHandle{} -> pure Nothing -- Not implemented yet
    LocalProcessHandle{} -> pure Nothing -- Not implemented yet
    RemoteHandle{} -> pure Nothing -- Not implemented yet 

-- | Create a specialized actor based on its role
deploySpecializedActor :: 
  (Member (Error ActorError) r) =>
  SimulationMode ->
  ActorSpec ->
  Sem r ActorHandle
deploySpecializedActor mode spec = do
  -- Create the base actor first
  baseActor <- createActor spec
  
  -- Deploy the appropriate specialized actor based on role
  case actorSpecRole spec of
    TimeTravelerRole -> do
      -- Create Time Traveler specification
      let travelerSpec = TimeTraveler.TimeTravelerSpec
            { TimeTraveler.travelerSpecId = actorSpecId spec
            , TimeTraveler.travelerSpecCapabilities = actorSpecCapabilities spec
            , TimeTraveler.travelerSpecInitialPrograms = actorSpecInitialPrograms spec
            , TimeTraveler.travelerSpecInitialResources = []  -- Initial resources would be added here
            }
      
      -- Deploy the actor
      deployActor baseActor mode
      
    TimeKeeperRole -> do
      -- Create Time Keeper specification
      let keeperSpec = TimeKeeper.TimeKeeperSpec
            { TimeKeeper.keeperSpecId = actorSpecId spec
            , TimeKeeper.keeperSpecCapabilities = actorSpecCapabilities spec
            , TimeKeeper.keeperSpecInitialTimelines = Map.empty  -- Initial timelines would be added here
            , TimeKeeper.keeperSpecInitialRules = Map.empty  -- Initial rules would be added here
            }
      
      -- Deploy the actor
      deployActor baseActor mode
      
    TimeBanditRole -> do
      -- Create Time Bandit specification
      let banditSpec = TimeBandit.TimeBanditSpec
            { TimeBandit.banditSpecId = actorSpecId spec
            , TimeBandit.banditSpecCapabilities = actorSpecCapabilities spec
            , TimeBandit.banditSpecNetwork = undefined  -- Network address would be set here
            , TimeBandit.banditSpecInitialPeers = []  -- Initial peers would be added here
            , TimeBandit.banditSpecInitialKeepers = Map.empty  -- Initial keepers would be added here
            }
      
      -- Deploy the actor
      deployActor baseActor mode

-- | Create a set of specialized actors for all required roles based on a list of actor specs
deploySpecializedActors ::
  (Member (Error ActorError) r) =>
  SimulationMode ->
  [ActorSpec] ->
  Sem r (Map Address ActorHandle)
deploySpecializedActors mode specs = do
  -- Deploy each specialized actor
  handles <- mapM (deploySpecializedActor mode) specs
  
  -- Create a map of handles by address
  let addressHandles = zip (map actorSpecId specs) handles
  return $ Map.fromList addressHandles 

-- | Deploy an actor in remote mode (for geo-distributed deployment)
deployRemoteActor :: (Member (Error ActorError) r, Member (Embed IO) r)
                 => ActorSpec
                 -> Sem r (ActorHandle r)
deployRemoteActor spec = do
  -- Create initial actor state
  state <- createActorState spec
  
  -- Generate a unique identifier for this remote actor
  remoteId <- embed $ getRandomBytes 16
  
  -- Get the current time for tracking
  now <- embed getCurrentTime
  
  -- Create network configuration for this actor
  let networkConfig = P2PConfig
        { pcBindAddress = SockAddrInet 0 0  -- Will be assigned by the system
        , pcBootstrapNodes = actorSpecBootstrapNodes spec
        , pcMaxConnections = 50  -- Default value
        , pcHeartbeatInterval = 30  -- 30 seconds
        , pcDiscoveryInterval = 300  -- 5 minutes
        , pcNodeCapabilities = actorSpecCapabilities spec
        }
  
  -- Convert to QUIC configuration
  let quicConfig = p2pConfigToQuicConfig networkConfig
  
  -- Start the QUIC server for this actor
  embed $ do
    -- Create the certificate directory if it doesn't exist
    createDirectoryIfMissing True "certs"
    
    -- In a real implementation, we would start a separate process or connect to a remote machine
    -- For now, we'll simulate this with a thread
    _ <- forkIO $ runM $ runError @AppError $ PT.traceToStdout $ do
      -- Start the QUIC server
      startQuicServer quicConfig (actorSpecActor spec) (actorSpecPubKey spec)
      
      -- Log that the server started
      PT.trace $ "Started QUIC server for actor " <> show (actorSpecId spec)
      
      -- Keep the server running
      embed $ forever $ threadDelay 1000000  -- 1 second
    
    -- Give the server time to start
    threadDelay 100000  -- 100ms
  
  -- Create a handle for the remote actor
  let handle = RemoteHandle
        { remoteId = remoteId
        , remoteHost = ""
        , remotePort = 8443
        , remoteSocket = Nothing
        , remoteActor = actorSpecActor spec
        , remoteState = state
        , remoteAddress = case actorSpecAddress spec of
            Just addr -> addr
            Nothing -> SockAddrInet 8443 0  -- Default QUIC port if not specified
        , remoteNetworkConfig = networkConfig
        , remoteLastSeen = now
        , remoteIsConnected = True
        }
  
  -- Return the handle
  return handle

-- | Helper function to get random bytes
getRandomBytes :: (Member (Embed IO) r) => Int -> Sem r ByteString
getRandomBytes n = embed $ BS.pack <$> replicateM n (randomRIO (0, 255))

-- | Helper function for random number generation
randomRIO :: (Integral a, Member (Embed IO) r) => (a, a) -> Sem r a
randomRIO (lo, hi) = embed $ do
  r <- randomIO
  return $ lo + fromIntegral (abs r `mod` fromIntegral (hi - lo + 1))

-- | Random number generator (would be properly imported in real implementation)
randomIO :: IO Int
randomIO = return 0  -- Placeholder, replace with actual implementation 