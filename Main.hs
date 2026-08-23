-----------------------------------------------------------------------------
{-# LANGUAGE LambdaCase         #-}
{-# LANGUAGE DeriveAnyClass     #-}
{-# LANGUAGE DeriveGeneric      #-}
{-# LANGUAGE StaticPointers     #-}
{-# LANGUAGE RecordWildCards    #-}
{-# LANGUAGE TemplateHaskell    #-}
{-# LANGUAGE OverloadedStrings  #-}
{-# LANGUAGE DerivingStrategies #-}
-----------------------------------------------------------------------------
-- | An exact port of the Lynx "Product Detail" tutorial
-- (<https://lynxjs.org/learn/product-detail>) to miso-native — a faithful
-- reproduction of the sample app at @lynx-family/lynx-examples/examples/swiper@
-- (its final @src/Swiper@ stage).
--
-- A hand-rolled, high-performance image swiper: a horizontal track of full-width
-- product photos dragged with the finger and snapped to the nearest page with an
-- eased tween on release, a page indicator that tracks the current page live and
-- supports click-to-jump, over the product-detail chrome (price card + order bar).
--
-- The port mirrors the sample's @useOffset@ / @useUpdateSwiperStyle@ / @useAnimate@
-- hooks: the touch handlers are 'onTouch*Main' (the sample's
-- @main-thread:bindtouch*@); the drag state it keeps in @useMainThreadRef@ lives
-- in the top-level 'IORef's below; 'updateOffsetIO' is @updateOffset@ (clamp +
-- @setStyleProperties@ + notify the indicator on a page flip); 'runAnimateIO' is
-- the @animate@ tween; @runOnBackground(onIndexUpdate)@ → 'SetCurrent';
-- @runOnMainThread(updateOffset)@ (click-to-jump) → 'JumpTo'.
--
-- @itemWidth@ is the sample's exact formula, @SystemInfo.pixelWidth /
-- SystemInfo.pixelRatio@ — read from its true home, @lynx.SystemInfo@. (ReactLynx
-- mirrors that onto @globalThis.SystemInfo@; miso does not, so a bare
-- @SystemInfo@ global is undefined here. See 'itemWidthPx'.)
module Main where
-----------------------------------------------------------------------------
import           Miso hiding (text_)
import           Miso.Native
import           Miso.Html.Property (className)
import qualified Miso.CSS as CSS
import           Miso.String (MisoString, ms)
import           Miso.Lens
import           Miso.Lens.TH
import           Miso.DSL (jsg, (!), fromJSValUnchecked)
import           Miso.Native.MainThread
  ( setStyleProperty, setStyleProperties, setStylePropertyTransform, eachFrame
  , getSystemInfo, SystemInfo(pixelWidth, pixelRatio)
  , MainThreadRef, mainThreadRef, readMainThreadRef
  , modifyMainThreadRef, modifyMainThreadRef_ )
import           System.IO.Unsafe (unsafePerformIO)
import           Control.Monad (when)
-----------------------------------------------------------------------------
import qualified Miso.Native.Element.View.Event as VE
import qualified Miso.Native.Element.Image.Property as IP
-----------------------------------------------------------------------------
import           Control.Monad.State
import           Miso.JSON (ToJSON, FromJSON)
import           GHC.Generics
-----------------------------------------------------------------------------
-- | Number of product photos in the swiper (assets @1.png@ .. @8.png@).
numPics :: Int
numPics = 8
-----------------------------------------------------------------------------
-- | All of the swiper's main-thread scratch — the sample's @useMainThreadRef@s,
-- grouped into one record behind a single 'MainThreadRef' (miso-native's
-- @useMainThreadRef@ equivalent). It is touched only inside MTS handlers / rAF
-- callbacks, so it never races the background thread. (It is a module global
-- rather than per-instance state; fine for the single mounted swiper here.)
data Drag = Drag
  { _startX      :: Double        -- ^ finger X at @touchstart@
  , _startOffset :: Double        -- ^ committed offset the drag began from
  , _curOffset   :: Double        -- ^ committed track offset (px; 0 at page 0, negative onward)
  , _pageIndex   :: Int           -- ^ page currently shown under the finger
  , _active      :: Bool          -- ^ finger currently down?
  , _wantOffset  :: Double        -- ^ latest offset the finger wants (written by @touchmove@)
  , _applied     :: Double        -- ^ offset the follow loop last painted (skip idle frames)
  , _velocity    :: Double        -- ^ smoothed finger velocity, px/ms (negative = swiping forward)
  , _lastTs      :: Double        -- ^ frame timestamp of the last velocity sample
  , _lastWant    :: Double        -- ^ 'wantOffset' at the last velocity sample
  , _track       :: Maybe DOMRef  -- ^ the track element, cached so click-to-jump can reach it
  }
-----------------------------------------------------------------------------
$(makeLenses ''Drag)
-----------------------------------------------------------------------------
data Action
  = TouchStart Double DOMRef
  -- ^ MTS: finger down at this clientX; anchor the drag and cancel any snap
  | TouchMove Double DOMRef
  -- ^ MTS: finger at this clientX; translate the track and (maybe) flip the page
  | TouchEnd DOMRef
  -- ^ MTS: finger up; animate a snap to the nearest page
  | Snapped Int
  -- ^ MTS→BTS: the drag settled on page i; hand it to the model-owning thread
  | SetCurrent Int
  -- ^ BTS: commit the current page (repaints the indicator)
  | JumpTo Int
  -- ^ BTS: a dot was tapped; set the page and glide the track
  | GlideTo Int
  -- ^ BTS→MTS: imperatively glide the track to page i
  deriving stock (Generic)
  deriving anyclass (ToJSON, FromJSON)
-----------------------------------------------------------------------------
-- | The only render-driving state is the page the indicator highlights. The
-- drag offset is deliberately absent — it is main-thread scratch ('currentOffsetRef').
newtype Model = Model
  { current :: Int
  } deriving stock (Eq, Generic)
    deriving anyclass (ToJSON, FromJSON)
-----------------------------------------------------------------------------
main :: IO ()
main = native VE.viewEvents (static (mountStatic swiperComponent))
-----------------------------------------------------------------------------
swiperComponent :: Component () () Model Action
swiperComponent = component (Model 0) updateModel viewModel
-----------------------------------------------------------------------------
-- | One page's width in px — the sample's @SystemInfo.pixelWidth /
-- SystemInfo.pixelRatio@, read from @lynx.SystemInfo@ via 'getSystemInfo' (its
-- real location; miso, unlike ReactLynx, does not mirror it onto @globalThis@).
-- 'getSystemInfo' is 'Nothing' off the main thread (and on a decode failure), in
-- which case we fall back to 0, so an absent global yields a blank swiper rather
-- than throwing during render. Each Lynx realm forces this CAF against its own
-- @lynx.SystemInfo@.
itemWidthPx :: Double
itemWidthPx = unsafePerformIO $ do
  msi <- getSystemInfo
  pure $ case msi of
    Just si | pixelRatio si > 0 -> pixelWidth si / pixelRatio si
    _                           -> 0
{-# NOINLINE itemWidthPx #-}
-----------------------------------------------------------------------------
-- Track geometry, all in terms of the single page width 'itemWidthPx'. Only
-- evaluated once it is > 0 (every caller guards), so the divisions are safe.
-----------------------------------------------------------------------------
-- | The track offset (px) that shows page @i@ (0, -w, -2w, …).
pageOffset :: Int -> Double
pageOffset i = negate (fromIntegral i * itemWidthPx)

-- | The page nearest a given track offset.
pageAt :: Double -> Int
pageAt off = round (negate off / itemWidthPx)

-- | Clamp an offset so the deck can't be pulled past either end.
clampOffset :: Double -> Double
clampOffset = max (pageOffset (numPics - 1)) . min 0

-- | Clamp a page index to the deck.
clampPage :: Int -> Int
clampPage = max 0 . min (numPics - 1)
-----------------------------------------------------------------------------
-- This is like MainThreadRef in lynx
drag :: MainThreadRef Drag
drag = mainThreadRef (Drag 0 0 0 0 False 0 0 0 0 0 Nothing)
{-# NOINLINE drag #-}
-----------------------------------------------------------------------------
readDrag :: IO Drag
readDrag = readMainThreadRef drag

modifyDrag :: (Drag -> Drag) -> IO ()
modifyDrag = modifyMainThreadRef drag

modifyDrag_ :: State Drag () -> IO ()
modifyDrag_ = modifyMainThreadRef_ drag
-----------------------------------------------------------------------------
updateModel :: Action -> Effect () () Model Action
updateModel = \case

  -- handleTouchStart: interrupt any in-flight snap (kill the transition so the
  -- track follows the finger 1:1), anchor the drag, start the vsync follow loop.
  TouchStart x ref -> io_ $ do
    d <- readDrag
    setStyleProperty ref "transition" "none"
    let off = _curOffset d
    modifyDrag_ $ do
      startX .= x
      startOffset .= off
      track ?= ref
      wantOffset .= off
      applied .= off
      active .= True
      velocity .= 0
      lastTs .= 0
      lastWant .= off
    when (not (_active d))
      (startDragLoop ref)

  -- handleTouchMove: just record where the finger wants the track. The follow
  -- loop applies it once per frame — cheap here, so bursty touchmoves don't jank.
  TouchMove x _ -> io_ $
    modifyDrag_ $ do
      so <- use startOffset
      sx <- use startX
      wantOffset .= so + (x - sx)

  -- handleTouchEnd: pick the target page (distance OR a flick), then hand the
  -- settle to a native CSS transition — no per-frame JS during the snap.
  TouchEnd ref -> withSink $ \sink -> do
    modifyDrag_ (active .= False)
    d <- readDrag
    when (itemWidthPx > 0) $ do
      let to  = snapTarget (_startOffset d) (_curOffset d) (_velocity d)
          idx = pageAt to
      modifyDrag_ $ do
        startX .= 0
        startOffset .= 0
        curOffset .= to
        pageIndex .= idx
      paintSnap ref to
      sink (Snapped idx)

  -- MTS→BTS: the model is owned by the background thread, so the settled page is
  -- forwarded there; 'SetCurrent' runs its 'update' on the BTS ('runOnBG').
  Snapped i -> runOnBG (SetCurrent i)

  -- BTS: commit the current page. Runs on the model-owning thread, so 'modify'
  -- repaints the indicator.
  SetCurrent i -> modify $ \m -> m { current = i }

  -- handleItemClick (BTS): set the page (repaints the dots), then glide the track
  -- imperatively on the MTS via 'runOnMain'.
  JumpTo i -> do
    modify $ \m -> m { current = i }
    runOnMain (GlideTo i)

  -- BTS→MTS: imperatively glide the track to page i (main-thread element write).
  GlideTo i -> io_ $ do
    d <- readDrag
    case _track d of
      Just ref
        | itemWidthPx > 0 -> do
            modifyDrag_ $ do
              curOffset .= pageOffset i
              pageIndex .= i
            paintSnap ref (pageOffset i)
      _ -> pure ()
-----------------------------------------------------------------------------
-- | Paint the track at @off@ (clamped) with no transition — the drag follow path,
-- run once per animation frame during a drag. The snap tween is already cleared
-- (@transition: none@ from 'TouchStart'), so this is an instant transform.
paintOffset :: DOMRef -> Double -> IO ()
paintOffset ref off = when (itemWidthPx > 0) $ do
  let real = clampOffset off
  setStylePropertyTransform ref [ CSS.translateX (CSS.px (round real)) ]
  modifyDrag_ $ do
    curOffset .= real
    pageIndex .= pageAt real
-----------------------------------------------------------------------------
-- | Settle to @to@ via a native compositor transition (ease-out) — the snap
-- runs off the JS thread, so there are no per-frame flushes during it.
paintSnap :: DOMRef -> Double -> IO ()
paintSnap ref to = setStyleProperties ref
  -- 'CSS.transition_' emits the single @transition@ *shorthand* key, the same one
  -- 'TouchStart' clears with @transition: none@. The longhands would be separate
  -- keys the reset can't reach, so @transition-duration@ would survive and turn
  -- every per-frame drag paint into a 0.3s tween.
  [ CSS.transition_ "transform" (CSS.s 0.3) (CSS.cubicBezier 0.22 1 0.36 1)
  , CSS.transforms [ CSS.translateX (CSS.px (round to)) ]
  ]
-----------------------------------------------------------------------------
-- | Where the swiper should settle after a drag. A page flips when the finger
-- either travelled past a fraction of a page (distance) __or__ was moving fast
-- enough when it lifted (a flick) — so a quick short swipe still advances. One
-- page per gesture, else spring back. A deliberate feel deviation from the
-- sample's @Math.round@ (distance-only, 50%).
--
--   * @startO@ — the committed offset the drag began from (a page boundary)
--   * @endO@   — the offset when the finger lifted
--   * @vel@    — smoothed finger velocity in px/ms (negative = forward)
snapTarget :: Double -> Double -> Double -> Double
snapTarget startO endO vel = pageOffset (clampPage (pageAt startO + step))
  where
    frac = negate (endO - startO) / itemWidthPx     -- fraction of a page dragged forward
    step | vel < negate velThresh =  1   -- a flick wins over distance…
         | vel >  velThresh       = -1
         | frac >  distThresh     =  1   -- …else fall back to how far it was dragged
         | frac < -distThresh     = -1
         | otherwise              =  0
    distThresh = 0.2      -- ~20% of a page commits the flip
    velThresh  = 0.3      -- px/ms (~300 px/s) counts as a flick
-----------------------------------------------------------------------------
-- | Fold this frame's finger motion into a smoothed velocity (px/ms). Skipped on
-- the first sample (no prior timestamp) and when no time has elapsed.
sampleVelocity :: Double -> Drag -> Drag
sampleVelocity ts s = s { _velocity = v, _lastTs = ts, _lastWant = _wantOffset s }
  where
    dt = ts - _lastTs s
    v | _lastTs s > 0 && dt > 0 = 0.6 * _velocity s + 0.4 * ((_wantOffset s - _lastWant s) / dt)
      | otherwise              = _velocity s
-----------------------------------------------------------------------------
-- | The vsync-coalesced drag follow loop. Each animation frame it samples the
-- finger velocity (for flick detection) and, if the finger moved, paints the
-- latest 'wantOffset' — coalescing the device's bursty @touchmove@ stream to one
-- flush per frame. Stops when 'active' clears (on touchend).
startDragLoop :: DOMRef -> IO ()
startDragLoop ref = eachFrame $ \ts -> do
  d <- readDrag
  if not (_active d)
    then pure False
    else do
      modifyDrag (sampleVelocity ts)
      when (_wantOffset d /= _applied d) $ do
        modifyDrag_ (applied .= _wantOffset d)
        paintOffset ref (_wantOffset d)
      pure True
-----------------------------------------------------------------------------
-- | The finger's window X (the sample's @e.touches[0].clientX@).
touchX :: VE.TouchEvent -> Double
touchX = fst . VE.client
-----------------------------------------------------------------------------
viewModel :: () -> () -> Model -> View () Model Action
viewModel _ _ Model{..} = view_ [ className "safe-area" ]
  [ view_ [ className "page-container" ]
    [ swiper current
    , cardDetail
    , orderButton
    ]
  ]
-----------------------------------------------------------------------------
-- | The swiper: a full-width viewport holding the draggable track (all touch
-- handling on the main thread) and the page indicator.
swiper :: Int -> View () Model Action
swiper cur = view_ [ className "swiper-wrapper" ]
  [ view_ [ className "swiper-container", touchStart, touchMove, touchEnd ]
      [ swiperItem i | i <- [0 .. numPics - 1] ]
  , indicator cur
  ]
  where
    touchStart = event (static (VE.onTouchStartMainWith (\t _ ref -> TouchStart (touchX t) ref)))
    touchMove  = event (static (VE.onTouchMoveMainWith  (\t _ ref -> TouchMove  (touchX t) ref)))
    touchEnd   = event (static (VE.onTouchEndMainWith   (\_ _ ref -> TouchEnd ref)))
-----------------------------------------------------------------------------
-- | One page: a full-width (100vw == itemWidth) cell with an aspect-filled photo.
swiperItem :: Int -> View () Model Action
swiperItem i = view_
  [ className "swiper-item"
  , CSS.style_ [ CSS.width (ms (show itemWidthPx) <> "px"), CSS.height "100%" ]
  ]
  [ image_ (asset (ms (i + 1) <> ".png"))
      [ IP.mode_ "aspectFill"
      , CSS.style_ [ CSS.width "100%", CSS.height "100%" ]
      ]
  ]
-----------------------------------------------------------------------------
-- | The dots. The active dot is a single-token class (native @className@ takes
-- one token per node), and tapping a dot jumps to that page.
indicator :: Int -> View () Model Action
indicator cur = view_ [ className "indicator" ]
  [ view_
      [ className (if i == cur then "indicator-item-active" else "indicator-item")
      , VE.onTap (JumpTo i)
      ]
      []
  | i <- [0 .. numPics - 1]
  ]
-----------------------------------------------------------------------------
-- | The floating price card: price, sales count, description, and a heart.
cardDetail :: View () Model Action
cardDetail = view_ [ className "card-detail-container" ]
  [ view_ [ className "card-detail" ]
    [ view_ [ className "card-detail-title" ]
      [ text_ [ className "card-detail-title-price" ] [ text "\65509\&1314" ]
      , text_ [ className "card-detail-amount" ] [ text "Sold 1000+" ]
      ]
    , view_ [ className "card-detail-desc" ]
      [ text_ [ className "card-detail-desc-text" ] [ text "Single leather seat" ]
      , image_ (asset "heart.png")
          [ IP.mode_ "aspectFill"
          , CSS.style_ [ CSS.width "20px", CSS.height "20px" ]
          ]
      ]
    ]
  ]
-----------------------------------------------------------------------------
-- | The bottom call-to-action bar.
orderButton :: View () Model Action
orderButton = view_ [ className "order-button" ]
  [ text_ [ className "order-text" ] [ text "Order Now" ] ]
-----------------------------------------------------------------------------
-- | Resolve a bundled image asset by name (e.g. @"1.png"@, @"heart.png"@) to the
-- @data:@ URI rspeedy embedded for it. rspeedy never sees the @src@ strings the
-- GHC JS backend emits, so @mkLynxBundle@ @import@s every asset with @?inline@
-- and registers them by name on @globalThis.__galleryAssets@; this reads it back.
asset :: MisoString -> MisoString
asset name = unsafePerformIO (jsg "__galleryAssets" >>= (! name) >>= fromJSValUnchecked)
{-# NOINLINE asset #-}
-----------------------------------------------------------------------------
