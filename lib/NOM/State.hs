module NOM.State (
  ProcessState (..),
  RunningBuildInfo,
  StorePathId,
  StorePathState (..),
  StorePathInfo (..),
  StorePathSet,
  StorePathMap,
  BuildInfo (..),
  BuildStatus (..),
  DependencySummary (..),
  DerivationId,
  DerivationInfo (..),
  DerivationSet,
  TransferInfo (..),
  NOMState,
  NOMV1State (..),
  getDerivationInfos,
  initalState,
  updateSummaryForStorePath,
  getStorePathInfos,
  NOMStateT,
  getRunningBuilds,
  getRunningBuildsByHost,
  lookupStorePathId,
  lookupDerivationId,
  getStorePathId,
  getDerivationId,
  out2drv,
  drv2out,
  updateSummaryForDerivation,
) where

import Relude

import Data.Generics.Product (HasField (field))
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Time (UTCTime)
import Optics ((%~))

import NOM.Builds (Derivation (..), FailType, Host (..), StorePath (..))
import NOM.State.CacheId (CacheId)
import NOM.State.CacheId.Map (CacheIdMap)
import NOM.State.CacheId.Map qualified as CMap
import NOM.State.CacheId.Set (CacheIdSet)
import NOM.State.CacheId.Set qualified as CSet
import NOM.Update.Monad (
  BuildReportMap,
  MonadCacheBuildReports (getCachedBuildReports),
  MonadNow,
  getNow,
 )
import NOM.Util (foldMapEndo, (.>), (<|>>), (|>))
import NOM.NixEvent.Action (ActivityId, Activity, ActivityProgress)

data StorePathState = DownloadPlanned | Downloading RunningTransferInfo | Uploading RunningTransferInfo | Downloaded CompletedTransferInfo | Uploaded CompletedTransferInfo
  deriving stock (Show, Eq, Ord, Generic)
  deriving anyclass (NFData)

data DerivationInfo = MkDerivationInfo
  { name :: Derivation
  , outputs :: Map Text StorePathId
  , inputDerivations :: Seq (DerivationId, Set Text)
  , inputSources :: StorePathSet
  , buildStatus :: BuildStatus
  , dependencySummary :: DependencySummary
  , cached :: Bool
  , derivationParents :: DerivationSet
  , pname :: Maybe Text
  , platform :: Maybe Text
  }
  deriving stock (Show, Eq, Ord, Generic)

type StorePathId = CacheId StorePath

type DerivationId = CacheId Derivation

type StorePathMap = CacheIdMap StorePath

type DerivationMap = CacheIdMap Derivation

type StorePathSet = CacheIdSet StorePath

type DerivationSet = CacheIdSet Derivation

data StorePathInfo = MkStorePathInfo
  { name :: StorePath
  , states :: Set StorePathState
  , producer :: Maybe DerivationId
  , inputFor :: DerivationSet
  }
  deriving stock (Show, Eq, Ord, Generic)
  deriving anyclass (NFData)

type RunningBuildInfo = BuildInfo ()

type CompletedBuildInfo = BuildInfo UTCTime

type RunningTransferInfo = TransferInfo UTCTime

type CompletedTransferInfo = TransferInfo (Maybe Int)

type FailedBuildInfo = BuildInfo (UTCTime, FailType)

data DependencySummary = MkDependencySummary
  { plannedBuilds :: DerivationSet
  , runningBuilds :: DerivationMap RunningBuildInfo
  , completedBuilds :: DerivationMap CompletedBuildInfo
  , failedBuilds :: DerivationMap FailedBuildInfo
  , plannedDownloads :: StorePathSet
  , completedDownloads :: StorePathMap CompletedTransferInfo
  , completedUploads :: StorePathMap CompletedTransferInfo
  , runningDownloads :: StorePathMap RunningTransferInfo
  , runningUploads :: StorePathMap RunningTransferInfo
  }
  deriving stock (Show, Eq, Ord, Generic)

data NOMV1State = MkNOMV1State
  { derivationInfos :: DerivationMap DerivationInfo
  , storePathInfos :: StorePathMap StorePathInfo
  , fullSummary :: DependencySummary
  , forestRoots :: Seq DerivationId
  , buildReports :: BuildReportMap
  , startTime :: UTCTime
  , processState :: ProcessState
  , storePathIds :: Map StorePath StorePathId
  , derivationIds :: Map Derivation DerivationId
  , touchedIds :: DerivationSet
  , activities :: IntMap (Activity, Maybe Text, Maybe ActivityProgress)
  , nixErrors :: [Text]
  }
  deriving stock (Show, Eq, Ord, Generic)

data ProcessState = JustStarted | InputReceived | Finished
  deriving stock (Show, Eq, Ord, Generic)

data BuildStatus
  = Unknown
  | Planned
  | Building (BuildInfo ())
  | Failed (BuildInfo (UTCTime, FailType)) -- End
  | Built (BuildInfo UTCTime) -- End
  deriving stock (Show, Eq, Ord, Generic)

data BuildInfo a = MkBuildInfo
  { start :: UTCTime
  , host :: Host
  , estimate :: Maybe Int
  , activityId :: Maybe ActivityId
  , end :: a
  }
  deriving stock (Show, Eq, Ord, Generic, Functor)

data TransferInfo a = MkTransferInfo
  { host :: Host
  , duration :: a
  }
  deriving stock (Show, Eq, Ord, Generic, Functor)
  deriving anyclass (NFData)

initalState :: (MonadCacheBuildReports m, MonadNow m) => m NOMV1State
initalState = do
  now <- getNow
  buildReports <- getCachedBuildReports
  pure $
    MkNOMV1State
      mempty
      mempty
      mempty
      mempty
      buildReports
      now
      JustStarted
      mempty
      mempty
      mempty
      mempty
      mempty

instance Semigroup DependencySummary where
  (MkDependencySummary ls1 lm2 lm3 lm4 ls5 lm6 lm7 lm8 lm9) <> (MkDependencySummary rs1 rm2 rm3 rm4 rs5 rm6 rm7 rm8 rm9) = MkDependencySummary (ls1 <> rs1) (lm2 <> rm2) (lm3 <> rm3) (lm4 <> rm4) (ls5 <> rs5) (lm6 <> rm6) (lm7 <> rm7) (lm8 <> rm8) (lm9 <> rm9)

instance Monoid DependencySummary where
  mempty = MkDependencySummary mempty mempty mempty mempty mempty mempty mempty mempty mempty

getRunningBuilds :: NOMState (DerivationMap RunningBuildInfo)
getRunningBuilds = gets (.fullSummary.runningBuilds)

getRunningBuildsByHost :: Host -> NOMState (DerivationMap RunningBuildInfo)
getRunningBuildsByHost host = getRunningBuilds <|>> CMap.filter (\x -> x.host == host)

lookupStorePathId :: StorePathId -> NOMState StorePath
lookupStorePathId pathId = getStorePathInfos pathId <|>> (.name)

lookupDerivationId :: DerivationId -> NOMState Derivation
lookupDerivationId drvId = getDerivationInfos drvId <|>> (.name)

type NOMState a = forall m. MonadState NOMV1State m => m a

type NOMStateT m a = MonadState NOMV1State m => m a

emptyStorePathInfo :: StorePath -> StorePathInfo
emptyStorePathInfo path = MkStorePathInfo path mempty Nothing mempty

emptyDerivationInfo :: Derivation -> DerivationInfo
emptyDerivationInfo drv = MkDerivationInfo drv mempty mempty mempty Unknown mempty False mempty Nothing Nothing

getStorePathId :: StorePath -> NOMState StorePathId
getStorePathId path = do
  let newId = do
        key <- gets ((.storePathInfos) .> CMap.nextKey)
        modify (field @"storePathInfos" %~ CMap.insert key (emptyStorePathInfo path))
        modify (field @"storePathIds" %~ Map.insert path key)
        pure key
  gets ((.storePathIds) .> Map.lookup path) >>= maybe newId pure

getDerivationId :: Derivation -> NOMState DerivationId
getDerivationId drv = do
  let newId = do
        key <- gets ((.derivationInfos) .> CMap.nextKey)
        modify (field @"derivationInfos" %~ CMap.insert key (emptyDerivationInfo drv))
        modify (field @"derivationIds" %~ Map.insert drv key)
        pure key
  gets ((.derivationIds) .> Map.lookup drv) >>= maybe newId pure

drv2out :: DerivationId -> NOMState (Maybe StorePath)
drv2out drv =
  gets ((.derivationInfos) .> CMap.lookup drv >=> (.outputs) .> Map.lookup "out")
    >>= mapM (\pathId -> lookupStorePathId pathId)

out2drv :: StorePathId -> NOMState (Maybe DerivationId)
out2drv path = gets ((.storePathInfos) .> CMap.lookup path >=> (.producer))

-- Only do this with derivationIds that you got via lookupDerivation
getDerivationInfos :: DerivationId -> NOMState DerivationInfo
getDerivationInfos drvId =
  get
    <|>> (.derivationInfos)
    .> CMap.lookup drvId
    .> fromMaybe (error "BUG: drvId is no key in derivationInfos")

-- Only do this with derivationIds that you got via lookupDerivation
getStorePathInfos :: StorePathId -> NOMState StorePathInfo
getStorePathInfos storePathId =
  get
    <|>> (.storePathInfos)
    .> CMap.lookup storePathId
    .> fromMaybe (error "BUG: storePathId is no key in storePathInfos")

updateSummaryForDerivation :: BuildStatus -> BuildStatus -> DerivationId -> DependencySummary -> DependencySummary
updateSummaryForDerivation oldStatus newStatus drvId = removeOld .> addNew
 where
  removeOld = case oldStatus of
    Unknown -> id
    Planned -> field @"plannedBuilds" %~ CSet.delete drvId
    Building _ -> field @"runningBuilds" %~ CMap.delete drvId
    Failed _ -> id
    Built _ -> id
  addNew = case newStatus of
    Unknown -> id
    Planned -> field @"plannedBuilds" %~ CSet.insert drvId
    Building bi -> field @"runningBuilds" %~ CMap.insert drvId (void bi)
    Failed bi -> field @"failedBuilds" %~ CMap.insert drvId bi
    Built bi -> field @"completedBuilds" %~ CMap.insert drvId bi

updateSummaryForStorePath :: Set StorePathState -> Set StorePathState -> StorePathId -> DependencySummary -> DependencySummary
updateSummaryForStorePath oldStates newStates pathId =
  foldMapEndo remove_deleted deletedStates
    .> foldMapEndo insert_added addedStates
 where
  remove_deleted :: StorePathState -> DependencySummary -> DependencySummary
  remove_deleted = \case
    DownloadPlanned -> field @"plannedDownloads" %~ CSet.delete pathId
    Downloading _ -> field @"runningDownloads" %~ CMap.delete pathId
    Uploading _ -> field @"runningUploads" %~ CMap.delete pathId
    Downloaded _ -> error "BUG: Don’t remove a completed download"
    Uploaded _ -> error "BUG: Don‘t remove a completed upload"
  insert_added :: StorePathState -> DependencySummary -> DependencySummary
  insert_added = \case
    DownloadPlanned -> field @"plannedDownloads" %~ CSet.insert pathId
    Downloading ho -> field @"runningDownloads" %~ CMap.insert pathId ho
    Uploading ho -> field @"runningUploads" %~ CMap.insert pathId ho
    Downloaded ho -> field @"completedDownloads" %~ CMap.insert pathId ho
    Uploaded ho -> field @"completedUploads" %~ CMap.insert pathId ho
  deletedStates = Set.difference oldStates newStates |> toList
  addedStates = Set.difference newStates oldStates |> toList
