{-# LANGUAGE ScopedTypeVariables #-}

-----------------------------------------------------------------------------
-- |
-- Module      : Control.Parallel.MPI.Base
-- Copyright   : (c) 2010 Bernie Pope, Dmitry Astapov
-- License     : BSD-style
-- Maintainer  : florbitous@gmail.com
-- Stability   : experimental
-- Portability : ghc
--
-- This module provides common MPI functionality that is independent of
-- the type of message
-- being transferred between processes. Many functions in this module bear
-- a close correspondence with those provided by the C API. Such
-- correspondences are noted in the documentation of this module where
-- relevant.
-----------------------------------------------------------------------------

module Control.Parallel.MPI.Base
   (
   -- * Notable changes from the C interface to MPI
   --
   -- ** Collective operations are split
   -- $collectives-split

   -- ** Reversed order of arguments
   -- $arg-order

   -- ** Rank checking in collective functions
   -- $rank-checking

   -- ** Error handling
   -- $err-handling

   -- * Example
   -- $example

   -- * Initialization, finalization, termination.
     init
   , finalize
   , initialized
   , finalized
   , mpi
   , mpiWorld
   , initThread
   , abort

     -- * Requests and statuses.
   , Request
   , Status (..)
   , probe
   , test
   , cancel
   , wait

   -- * Communicators and error handlers.
   , Comm
   , commWorld
   , commSelf
   , commSize
   , commRank
   , commTestInter
   , commRemoteSize
   , commCompare
   , commSetErrhandler
   , commGetErrhandler
   , commGroup
   , Errhandler
   , errorsAreFatal
   , errorsReturn

   -- * Tags.
   , Tag
   , toTag
   , fromTag
   , anyTag
   , unitTag
   , tagUpperBound

   -- Ranks.
   , Rank
   , rankId
   , toRank
   , fromRank
   , anySource
   , theRoot
   , procNull

   -- * Synchronization.
   , barrier

   -- * Futures.
   , Future(..)   -- XXX should this be exported abstractly? Internals needed in Serializable.
   , waitFuture
   , getFutureStatus
   , pollFuture
   , cancelFuture

   -- * Groups.
   , Group
   , groupEmpty
   , groupRank
   , groupSize
   , groupUnion
   , groupIntersection
   , groupDifference
   , groupCompare
   , groupExcl
   , groupIncl
   , groupTranslateRanks

   -- * Data types.
   , Datatype
   , char
   , wchar
   , short
   , int
   , long
   , longLong
   , unsignedChar
   , unsignedShort
   , unsigned
   , unsignedLong
   , unsignedLongLong
   , float
   , double
   , longDouble
   , byte
   , packed
   , typeSize

   -- * Operators.
   , Operation
   , maxOp
   , minOp
   , sumOp
   , prodOp
   , landOp
   , bandOp
   , lorOp
   , borOp
   , lxorOp
   , bxorOp

   -- * Comparisons.
   , ComparisonResult (..)

   -- * Threads.
   , ThreadSupport (..)
   , queryThread
   , isThreadMain

   -- * Timing.
   , wtime
   , wtick
   , wtimeIsGlobal

   -- * Environment.
   , getProcessorName
   , Version (..)
   , getVersion

   -- * Error handling.
   , MPIError(..)
   , ErrorClass(..)
   ) where

import Prelude hiding (init)
import Control.Exception (finally)
import Control.Concurrent.MVar (MVar, tryTakeMVar, readMVar)
import Control.Concurrent (ThreadId, killThread)
import Control.Parallel.MPI.Internal

-- | A convenience wrapper which takes an MPI computation as its argument and wraps it
-- inside calls to 'init' (before the computation) and 'finalize' (after the computation).
-- It will make sure that 'finalize' is called even if the MPI computation raises
-- an exception (assuming the error handler is set to 'errorsThrowExceptions').
mpi :: IO () -> IO ()
mpi action = init >> (action `finally` finalize)

-- | A convenience wrapper with a similar behaviour to 'mpi'.
-- The difference is that the MPI computation is a function which is abstracted over
-- the communicator size and the process rank, both with respect to 'commWorld'.
--
-- @
-- main = mpiWorld $ \\size rank -> do
--    ...
--    ...
-- @
mpiWorld :: (Int -> Rank -> IO ()) -> IO ()
mpiWorld action = do
   init
   size <- commSize commWorld
   rank <- commRank commWorld
   action size rank `finally` finalize

-- | A value to be computed by some thread in the future.
data Future a =
   Future
   { futureThread :: ThreadId
   , futureStatus :: MVar Status
   , futureVal :: MVar a
   }

-- | Obtain the computed value from a 'Future'. If the computation
-- has not completed, the caller will block, until the value is ready.
-- See 'pollFuture' for a non-blocking variant.
waitFuture :: Future a -> IO a
waitFuture = readMVar . futureVal

-- | Obtain the 'Status' from a 'Future'. If the computation
-- has not completed, the caller will block, until the value is ready.
getFutureStatus :: Future a -> IO Status
getFutureStatus = readMVar . futureStatus
-- XXX do we need a pollStatus?

-- | Poll for the computed value from a 'Future'. If the computation
-- has not completed, the function will return @None@, otherwise it
-- will return @Just value@.
pollFuture :: Future a -> IO (Maybe a)
pollFuture = tryTakeMVar . futureVal

-- | Terminate the computation associated with a 'Future'.
cancelFuture :: Future a -> IO ()
cancelFuture = killThread . futureThread
-- XXX May want to stop people from waiting on Futures which are killed...

{- $collectives-split
Collective operations in MPI usually take a large set of arguments
that include pointers to both the input and output buffers. This fits
nicely in the C programming style, which follows this pattern:

 1. Pointers to send and receive buffers are declared.

 2. if (my_rank == root) then (send buffer is allocated and filled)

 3. Both pointers are passed to a collective function, which ignores
    the unallocated send buffer for all non-root processes.

However this style of programming is not idiomatic in Haskell.
Therefore it was decided to split most asymmetric collective calls into
two parts - sending and receiving. Thus @MPI_Gather@ is represented by
'gatherSend' and 'gatherRecv', and so on. -}

{- $arg-order
The order of arguments to most of the Haskell communication operators
is different than that of the corresponding C functions.
This was motivated by the desire to make partial application
more natural for the common case where the communicator,
rank and tag are fixed but the message varies.
-}

{- $rank-checking
Collective operations that are split into separate send/recv parts
(see above) take "root rank" as an argument. Right now no safeguards
are in place to ensure that rank supplied to the send function is
corresponding to the rank of that process. We believe that it does not
worsen the general go-on-and-shoot-yourself-in-the-foot attitide of
the MPI API.
-}

{- $err-handling
Most MPI functions may fail with an error, which, by default, will cause
the program to abort. This can be changed by setting the error
handler to 'errorsThrowExceptions'. As the name suggests, this will
turn the error into an exception which can be handled using
the facilities provided by the "Control.Exception" module.
-}

{-$example
Below is a small but complete MPI program. Process 1 sends the message
@\"Hello World\"@ to process 0. Process 0 receives the message and prints it
to standard output. It assumes that there are at least 2 MPI processes
available; a more robust program would check this condition first, before
trying to send messages.

@
module Main where

import "Control.Parallel.MPI" (mpi, commRank, commWorld, unitTag)
import "Control.Parallel.MPI.Serializable" (send, recv)
import Control.Monad (when)

main :: IO ()
main = 'mpi' $ do
   rank <- 'commRank' 'commWorld'
   when (rank == 1) $
      'send' 'commWorld' 0 'unitTag' \"Hello World\"
   when (rank == 0) $ do
      (msg, _status) <- 'recv' 'commWorld' 1 'unitTag'
      putStrLn msg
@
-}
