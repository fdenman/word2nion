-- {-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE PartialTypeSignatures #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE NoStarIsType #-}

-- | Defines a model similar to the one defined in the word2vec papers
-- except it is represented by quaternions and it can support aribitrary lenghts
-- of sequences.
--
module Models.QuaternionSelfSupervised where

import Barbies
import Control.Exception.Safe (SomeException (..), try)
import Control.Monad (foldM, when)
import Control.Monad.Catch
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Trans.Control hiding (embed)
import Data.Bifunctor (second)
import Data.Functor.Const
import Data.Functor.Identity
import Data.Functor.Product (Product (..))
import qualified Data.Monoid.Statistics as StatM
import Data.Proxy
import Data.Sequence (Seq)
import qualified Data.Sequence as Seq
import Foreign.ForeignPtr
import GHC.Generics
import GHC.TypeLits
import GHC.TypeLits.Extra
import Generic.Data (Generically (..))
import Graphics.Vega.VegaLite hiding (Identity)
import Streamly
import Streamly
import qualified Streamly.Prelude as S
import System.Environment
import System.IO.Unsafe
import System.Random
import Torch.Streamly.Dataloader
import qualified Torch.Autograd as A
import qualified Torch.DType as D
import qualified Torch.Device as D
import qualified Torch.Functional as D
import qualified Torch.Internal.Cast as ATen
import qualified Torch.Internal.Class as ATen
import qualified Torch.Internal.Managed.Type.Context as ATen
import qualified Torch.Internal.Managed.Type.Tensor as ATen
import qualified Torch.Internal.Type as ATen
import qualified Torch.NN as A
import qualified Torch.Tensor as D
import qualified Torch.TensorFactories as D
import Torch.Typed.Aux
import Torch.Typed.Factories
import Torch.Typed.Functional hiding
  ( conv2d,
    linear,
  )
import Torch.Typed.NN
import Torch.Typed.Parameter
import Torch.Typed.Quaternion
import Torch.Typed.Tensor
import Trainer
import Prelude hiding (abs, tanh)

-- | (Vanilla) quaternion model is just an embedding matrix of size (vocabSize, featureSize)
--
data Word2Quat vocabSize featureSize dtype device where
  Word2Quat ::
    forall vocabSize featureSize dtype device.
    { embed0 :: Embedding 'Nothing vocabSize featureSize 'Learned dtype device
    --   fc0 :: Linear featureSize 1 dtype device,
    --   w2qDropout :: Dropout
    } ->
    Word2Quat vocabSize featureSize dtype device
  deriving stock (Show, Generic)

-- | The initialization spec is boring in this case
data Word2QuatSpec vocabSize featureSize dtype device where
  Word2QuatSpec :: Word2QuatSpec vocabSize featureSize dtype device
  deriving stock (Show, Generic)

-- | ... we just initialize the matrix with random quaternions.
--
instance
  ( KnownDType dtype,
    KnownDevice device,
    RandDTypeIsValid device dtype,
    HasQuaternions featureSize,
    DivisionProofs featureSize 4,
    All KnownNat '[featureSize, vocabSize],
    StandardFloatingPointDTypeValidation
      device
      dtype,
    SumDTypeIsValid device dtype,
    SumDType dtype ~ dtype
  ) =>
  A.Randomizable
    (Word2QuatSpec vocabSize featureSize dtype device)
    (Word2Quat vocabSize featureSize dtype device)
  where
  sample Word2QuatSpec = do
    init' <- catQuaternions @'[vocabSize, (Div featureSize 4)] <$> initialize @vocabSize @(Div featureSize 4)
    Word2Quat
      <$> A.sample (LearnedEmbeddingWithCustomInitSpec @'Nothing @vocabSize @featureSize @dtype @device init')
    --   <*> A.sample (LinearSpec)
    --   <*> A.sample (DropoutSpec w2qDropoutProbSpec)

-- | The forward propagation function.  It takes a model, a boolean designating dropout use (unused), and input data
-- in the form of a list of tokens in a sequence (of `batchSize` individual sequences). output is a tensor of mean squared
-- errors (where error is cacluated as the average squared distance between all intermediary states and next tokens for all batches) over each sequence.
--
-- Interesting idea: in word2vec, we ask the word reps to be similar subject to their co-occurance
-- Instead of asking them to be similar, what if we ask them to maximize their effective complexity?
-- We can take the output of `approxDistances` to be a probability distibution for shannon entropy:
-- Ie, a vector populated by probabilities.  In this case, the entropy is 0 when q1 and q2 are the same.
-- intuitively, this makes sense: if the total of all previous words in a text perfectly imply the next word,
-- there's zero uncertainty between them.  Conversly, if q2 comes out of nowhere, thre's higher uncertainty.
-- The AIC (Komogorov Complexity) can be estimated by learning an autoencoder that tries to compress the quaternions
-- themselves.  This will output a reconstruction error that is a metric of relative uncompressability and
-- approximates KC. Shhould the AIC be estimated on the quaternions of q1 and q2?  I suppose it needs to since
-- the shannon entropy depends on both.
--
word2Quat ::
  forall batchSize vocabSize featureSize dim dtype device.
  ( HasQuaternionComponents '[batchSize, featureSize] dim featureSize device dtype,
    'True ~ (1 <=? (Div featureSize 4)),
    'True ~ (1 <=? batchSize),
    CanNormalize '[batchSize, featureSize] device dtype,
    MeanDTypeValidation device dtype
  ) =>
  Word2Quat vocabSize featureSize dtype device ->
  Bool ->
  [Tensor device 'D.Int64 '[batchSize]] ->
  IO (Tensor device dtype '[batchSize])
word2Quat Word2Quat {..} _stochastic input = do
  let e = reshape @'[batchSize,featureSize] . forward embed0 <$> input
  let r' = hamiltonReduce Nothing e
  pure . meanDim @1 . mulScalar (1.0 / (fromIntegral $ length r') :: Double) . sum $ (\ (q1, q2) -> pow (2 :: Int) $ approxDistances q1 q2) <$> byTwos r' 

