-- SPDX-FileCopyrightText: 2022 Serokell <https://serokell.io>
-- SPDX-License-Identifier: MPL-2.0

-- for inequality on keygen
{-# OPTIONS_GHC -Wno-redundant-constraints #-}

module Crypto.BLST
  ( -- * Main functions
    keygen
  , deriveMasterEIP2333
  , deriveChildEIP2333
  , skToPk
  , sign
  , verify
  , serializeSk
  , deserializeSk
  , serializePk
  , deserializePk
  , compressPk
  , decompressPk
  , serializeSignature
  , deserializeSignature
  , compressSignature
  , decompressSignature

    -- * Aggregate signatures
  , aggregateSignatures
  , aggregateVerify

    -- * Representation datatypes
  , SecretKey
  , PublicKey
  , Signature
  , B.BlstError(..)

    -- * Utility typeclasses
  , IsCurve
  , IsPoint
  , ToCurve
  , Demote

    -- * Data kinds
  , Curve(..)
  , B.EncodeMethod(..)

    -- * Typelevel byte sizes
  , ByteSize
  , SerializeOrCompress(..)

    -- * Misc helpers
  , noDST
  , byteSize
  ) where

import Control.Exception (catch, throwIO)
import Control.Monad (forM_)
import Data.ByteArray (ByteArrayAccess, Bytes, ScrubbedBytes)
import Data.ByteArray.Sized (SizedByteArray, unSizedByteArray)
import Data.Foldable (foldlM)
import Data.List.NonEmpty (NonEmpty(..))
import GHC.TypeNats (KnownNat, type (<=))
import System.IO.Unsafe (unsafePerformIO)

import Crypto.BLST.Internal.Bindings qualified as B
import Crypto.BLST.Internal.Classy
import Crypto.BLST.Internal.Demote
import Crypto.BLST.Internal.Types
import Foreign.C.Types (CUInt)

-- | Generate a secret key from bytes.
keygen :: (ByteArrayAccess ba, 32 <= n, KnownNat n) => SizedByteArray n ba -> SecretKey
keygen = SecretKey . unsafePerformIO . B.keygen . unSizedByteArray
{-# NOINLINE keygen #-}

deriveMasterEIP2333 :: (ByteArrayAccess ba, 32 <= n, KnownNat n) => SizedByteArray n ba -> SecretKey
deriveMasterEIP2333 = SecretKey . unsafePerformIO . B.deriveMasterEIP2333

deriveChildEIP2333 :: SecretKey -> CUInt -> SecretKey
deriveChildEIP2333 (SecretKey s) = SecretKey . unsafePerformIO . B.deriveChildEIP2333 s

-- | Convert a secret key to the corresponding public key on a given curve.
skToPk :: forall c. IsCurve c => SecretKey -> PublicKey c
skToPk (SecretKey sk) = PublicKey $ unsafePerformIO $ skToPkPoint sk >>= toAffine
{-# NOINLINE skToPk #-}

-- | Serialize public key.
serializePk
  :: forall c. IsCurve c
  => PublicKey c
  -> SizedByteArray (SerializedSize (CurveToPkPoint c)) Bytes
serializePk (PublicKey pk) = unsafePerformIO $ affSerialize pk
{-# NOINLINE serializePk #-}

-- | Deserialize public key.
deserializePk
  :: forall c ba. (IsCurve c, ByteArrayAccess ba)
  => SizedByteArray (SerializedSize (CurveToPkPoint c)) ba
  -> Either B.BlstError (PublicKey c)
deserializePk bs = unsafePerformIO $ fmap PublicKey <$> deserialize bs
{-# NOINLINE deserializePk #-}

-- | Compress public key.
compressPk
  :: forall c. IsCurve c
  => PublicKey c
  -> SizedByteArray (CompressedSize (CurveToPkPoint c)) Bytes
compressPk (PublicKey pk) = unsafePerformIO $ affCompress pk
{-# NOINLINE compressPk #-}

-- | Decompress public key.
decompressPk
  :: forall c ba. (IsCurve c, ByteArrayAccess ba)
  => SizedByteArray (CompressedSize (CurveToPkPoint c)) ba
  -> Either B.BlstError (PublicKey c)
decompressPk bs = unsafePerformIO $ fmap PublicKey <$> uncompress bs
{-# NOINLINE decompressPk #-}

-- | Sign a single message.
sign
  :: forall c m ba ba2. (ToCurve m c, ByteArrayAccess ba, ByteArrayAccess ba2)
  => SecretKey -- ^ Secret key
  -> ba -- ^ Message to sign
  -> Maybe ba2 -- ^ Optional domain separation tag
  -> Signature c m
sign (SecretKey sk) bytes dst = Signature $ unsafePerformIO $ do
  encMsg <- toCurve @m bytes dst
  signPk encMsg sk >>= toAffine
{-# NOINLINE sign #-}

-- | Serialize message signature.
serializeSignature
  :: forall c m. IsCurve c
  => Signature c m
  -> SizedByteArray (SerializedSize (CurveToMsgPoint c)) Bytes
serializeSignature (Signature sig) = unsafePerformIO $ affSerialize sig
{-# NOINLINE serializeSignature #-}

-- | Deserialize message signature.
deserializeSignature
  :: forall c m ba. (IsCurve c, ByteArrayAccess ba)
  => SizedByteArray (SerializedSize (CurveToMsgPoint c)) ba
  -> Either B.BlstError (Signature c m)
deserializeSignature bs = unsafePerformIO $ fmap Signature <$> deserialize bs
{-# NOINLINE deserializeSignature #-}

-- | Serialize and compress message signature.
compressSignature
  :: forall c m. IsCurve c
  => Signature c m
  -> SizedByteArray (CompressedSize (CurveToMsgPoint c)) Bytes
compressSignature (Signature sig) = unsafePerformIO $ affCompress sig
{-# NOINLINE compressSignature #-}

-- | Decompress and deserialize message signature.
decompressSignature
  :: forall c m ba. (IsCurve c, ByteArrayAccess ba)
  => SizedByteArray (CompressedSize (CurveToMsgPoint c)) ba
  -> Either B.BlstError (Signature c m)
decompressSignature bs = unsafePerformIO $ fmap Signature <$> uncompress bs
{-# NOINLINE decompressSignature #-}

-- | Verify message signature.
verify
  :: forall c m ba ba2. (IsCurve c, Demote m, ByteArrayAccess ba, ByteArrayAccess ba2)
  => Signature c m -- ^ Signature
  -> PublicKey c -- ^ Public key of the signer
  -> ba -- ^ Message
  -> Maybe ba2 -- ^ Optional domain separation tag (must be the same as used for signing!)
  -> B.BlstError
verify (Signature sig) (PublicKey pk) bytes dst =
  unsafePerformIO $ coreVerifyPk pk sig meth bytes dst
  where
    meth = demote @m
{-# NOINLINE verify #-}

-- | Convenience synonym for 'Nothing'. Do not use domain separation tag.
noDST :: Maybe Bytes
noDST = Nothing

-- | Serialize secret key.
serializeSk :: SecretKey -> SizedByteArray B.SkSerializeSize ScrubbedBytes
serializeSk (SecretKey sk) = unsafePerformIO $ B.lendianFromScalar sk
{-# NOINLINE serializeSk #-}

-- | Deserialize secret key.
deserializeSk :: ByteArrayAccess ba => SizedByteArray B.SkSerializeSize ba -> SecretKey
deserializeSk bs = SecretKey $ unsafePerformIO $ B.scalarFromLendian bs
{-# NOINLINE deserializeSk #-}

-- | Aggregate multiple signatures.
aggregateSignatures :: forall c m. IsCurve c => NonEmpty (Signature c m) -> Signature c m
aggregateSignatures (Signature x :| xs) = Signature . unsafePerformIO $ do
  start <- fromAffine x
  foldlM add start xs >>= toAffine
  where
    add x' (Signature y) = addOrDoubleAffine x' y
{-# NOINLINE aggregateSignatures #-}

-- | Aggregate signature verification.
aggregateVerify
  :: forall c m ba ba2. (IsCurve c, Demote m, ByteArrayAccess ba, ByteArrayAccess ba2)
  => NonEmpty (PublicKey c, ba) -- ^ Public keys with corresponding messages
  -> Signature c m -- ^ Aggregate signature
  -> Maybe ba2 -- ^ Optional domain separation tag (must be the same as used for signing!)
  -> Either B.BlstError Bool
aggregateVerify ((PublicKey pk1, msg1) :| xs) (Signature sig) dst = unsafePerformIO $ do
  ctx <- B.pairingInit (demote @m) dst
  checkThrow =<< pairingChkNAggrPk ctx pk1 True (Just sig) True msg1
  forM_ xs $ \(PublicKey pki, msgi) ->
    checkThrow =<< pairingChkNAggrPk ctx pki True Nothing True msgi
  B.pairingCommit ctx
  Right <$> B.pairingFinalVerify ctx
  `catch` \(err :: B.BlstError) -> pure $ Left err
  where
    checkThrow = \case
      B.BlstSuccess -> pure ()
      x -> throwIO x
{-# NOINLINE aggregateVerify #-}
