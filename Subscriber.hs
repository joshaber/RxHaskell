{-# LANGUAGE Safe #-}

module Subscriber ( Subscriber
                  , subscriber
                  , send
                  , OnEvent
                  ) where

import Control.Applicative
import Control.Concurrent
import Control.Concurrent.STM
import Control.Monad
import Data.Word
import Disposable
import Event

-- | A function to run when a signal sends an event.
type OnEvent a = Event a -> IO ()

-- | Receives events from a signal.
data Subscriber a = Subscriber {
    onEvent :: OnEvent a,
    disposable :: Disposable,
    lockedThread :: TVar ThreadId,
    threadLockCounter :: TVar Word32,
    disposed :: TVar Bool
}

-- | Constructs a subscriber.
subscriber :: OnEvent a -> IO (Subscriber a)
subscriber f = do
    b <- atomically $ newTVar False
    d <- newDisposable $ atomically $ writeTVar b True

    tid <- myThreadId
    lt <- atomically $ newTVar tid
    tlc <- atomically $ newTVar 0

    return Subscriber {
        onEvent = f,
        disposable = d,
        lockedThread = lt,
        threadLockCounter = tlc,
        disposed = b
    }

-- | Acquires a subscriber for the specified thread.
acquireSubscriber :: Subscriber a -> ThreadId -> STM Bool
acquireSubscriber sub tid = do
    d <- readTVar (disposed sub)
    if d
        then return False
        else do
            tlc <- readTVar (threadLockCounter sub)
            lt <- readTVar (lockedThread sub)
            when (tlc > 0 && lt /= tid) retry

            writeTVar (lockedThread sub) tid
            writeTVar (threadLockCounter sub) $ tlc + 1
            return True

-- | Releases a subscriber from the specified thread's ownership.
releaseSubscriber :: Subscriber a -> ThreadId -> STM ()
releaseSubscriber sub tid = do
    always $ fmap (== tid) $ readTVar (lockedThread sub)

    tlc <- readTVar (threadLockCounter sub)
    always $ return $ tlc > 0

    writeTVar (threadLockCounter sub) $ tlc - 1

-- | Sends an event to a subscriber.
send :: Subscriber a -> Event a -> IO ()
send s ev =
    let send' s ev@(NextEvent _) = onEvent s ev
        send' s ev = do
            d <- dispose (disposable s)
            unless d $ onEvent s ev
    in do
        tid <- myThreadId
        b <- atomically $ acquireSubscriber s tid

        when b $ send' s ev >> atomically (releaseSubscriber s tid)
