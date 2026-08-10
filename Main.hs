-----------------------------------------------------------------------------
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE DeriveAnyClass    #-}
{-# LANGUAGE DeriveGeneric     #-}
{-# LANGUAGE StaticPointers    #-}
{-# LANGUAGE RecordWildCards   #-}
{-# LANGUAGE OverloadedLists   #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DerivingStrategies #-}
-----------------------------------------------------------------------------
-- | A faithful port of the Lynx "Product Gallery" tutorial
-- (<https://lynxjs.org/learn/gallery>) to miso-native.
--
-- It reproduces the same app: a black, full-height page with a two-column
-- __waterfall__ <list> of rounded image cards, each with a heart "like"
-- button that turns red and fires a one-shot ripple, a gradient custom
-- scrollbar pinned to the right edge whose height/offset track the scroll
-- position, and an __auto-scroll__ that starts on mount (rate 60).
--
-- The keyframe animations (@ripple@, @flow@) and the class-based rules live in
-- @sample-app-native/styles.css@ (compiled under the global cssId 0 the runtime
-- scopes the page to) — the Lynx way to do class CSS. Keyframes cannot be
-- expressed inline, so the visual classes are matched 1:1 there; only the
-- dynamic scrollbar height/top and per-image aspect-ratio are inline.
module Main where
-----------------------------------------------------------------------------
import           Miso hiding (text_)
import           Miso.Native
import           Miso.Html.Property (id_, className)
import qualified Miso.CSS as CSS
import           Miso.String (MisoString, ms)
import           Miso.DSL (jsg, (!), fromJSValUnchecked)
import           System.IO.Unsafe (unsafePerformIO)
-----------------------------------------------------------------------------
import qualified Miso.Native.Element.View.Event     as VE
import qualified Miso.Native.Element.Image.Property  as IP
import           Miso.Native.Element.List.Property
  ( ListOptions(..), ListType(..), ScrollOrientation(..), itemKey_, enableScroll_
  , estimatedMainAxisSizePx_, preloadBufferCount_ )
import           Miso.Native.Element.List.Method
  (autoScroll, defaultAutoScroll, AutoScroll(..))
-----------------------------------------------------------------------------
import           Miso.JSON (ToJSON, FromJSON)
import           GHC.Generics
-----------------------------------------------------------------------------
data Action
  = Like Int
  -- ^ tap a card's heart: toggle its liked state (BTS; re-renders)
  | StartScroll
  -- ^ fired once on mount: kick off the native @autoScroll@ (rate 60)
  | Noop
  -- ^ invoke callbacks (success/failure), ignored
  deriving stock (Generic)
  deriving anyclass (ToJSON, FromJSON)
-----------------------------------------------------------------------------
-- | The model holds only what a re-render should depend on: the liked set. The
-- scroll geometry and drag anchor are deliberately __not__ here — driving them
-- through the model would re-render all 75 cards on every scroll frame, which is
-- the jank we're avoiding. Scroll tracking is imperative on the main thread; the
-- drag anchor lives in 'dragAnchor'.
newtype Model = Model
  { liked :: [Int]
    -- ^ indices of liked cards
  } deriving stock (Eq, Generic)
    deriving anyclass (ToJSON, FromJSON)
-----------------------------------------------------------------------------
main :: IO ()
main = do
  -- enableDebugging
  native [("tap", BUBBLE)] (static (mountStatic_ galleryComponent))
-----------------------------------------------------------------------------
galleryComponent :: Component () () Model Action
galleryComponent =
  (component (Model []) updateModel viewModel)
    { mount = Just StartScroll }
-----------------------------------------------------------------------------
-- | @id@ selector for the <list>, targeted by the @autoScroll@ UI method.
galleryListSel :: MisoString
galleryListSel = "#gallery-list"
-----------------------------------------------------------------------------
updateModel :: Action -> Effect () () Model Action
updateModel = \case
  Like i ->
    -- toggle: tapping a filled heart unlikes it
    modify $ \m -> m { liked = if i `elem` liked m
                                 then filter (/= i) (liked m)
                                 else i : liked m }
  StartScroll ->
    -- rate 60, start; autoStop False so it keeps scrolling (tutorial parity)
    autoScroll galleryListSel defaultAutoScroll { autoStop = False }
      (const Noop) (const Noop)
  Noop ->
    pure ()
-----------------------------------------------------------------------------
viewModel :: () -> () -> Model -> View () Model Action
viewModel _ _ Model{..} = view_
  [ className "gallery-wrapper" ]
  [ list_ (ListOptions Waterfall 2 Vertical)
    [ id_ "gallery-list"
    , className "list"
    , enableScroll_ True
    -- Give unmeasured cells a realistic height estimate and preload a few
    -- off-screen cells, so the recycler scrolls smoothly on the first pass.
    , estimatedMainAxisSizePx_ 200
    , preloadBufferCount_ 8
    ]
    [ card liked i | i <- [0 .. galleryCount - 1] ]
  ]
-----------------------------------------------------------------------------
-- | One waterfall card: a rounded image with a like-icon overlay.
card :: [Int] -> Int -> View () Model Action
card likedList i = listItem_
  [ itemKey_ ("pic-" <> ms i) ]
  [ view_ [ className "picture-wrapper" ]
    [ image_ (picUrl i)
      [ IP.mode_ "aspectFill"
      , CSS.style_ [ CSS.width "100%", CSS.aspectRatio (picAspect i) ]
      ]
    , likeIcon (i `elem` likedList) i
    ]
  ]
-----------------------------------------------------------------------------
-- | Top-right heart. The tutorial's @whiteHeart.png@ until liked, then
-- @redHeart.png@; liking renders the two ripple circles, whose one-shot
-- @ripple@ keyframe fires as they mount. Tapping again unlikes (toggles).
likeIcon :: Bool -> Int -> View () Model Action
likeIcon isLiked i = view_
  [ className "like-icon", VE.onTap (Like i) ]
  ( ripples ++
    [ image_ (asset (if isLiked then "redHeart.png" else "whiteHeart.png"))
      [ CSS.style_ [ CSS.width "40px", CSS.height "40px" ] ]
    ]
  )
  where
    ripples
      | isLiked   = [ view_ [ className "circle" ] []
                    , view_ [ className "circle-after" ] [] ]
      | otherwise = []
-----------------------------------------------------------------------------
-- | Resolve a bundled image asset by its relative name (e.g.
-- @"furnitures/0.png"@, @"redHeart.png"@) to the @data:@ URI rspeedy embedded
-- for it.
--
-- We can't reference images by path the way we reference CSS by @className@:
-- rspeedy never sees our GHC-generated @src@ strings, and the Lynx \<image\>
-- element doesn't resolve a relative @src@ against the bundle URL. Instead the
-- @bundle-lynx@ recipe @import@s every asset with @?inline@ (so rspeedy embeds
-- it as a @data:@ URI /in the bundle/) and registers them by name on
-- @globalThis.__galleryAssets@. This reads that registry back.
--
-- The registry is populated once at bundle load and never mutates, so the read
-- is referentially transparent.
asset :: MisoString -> MisoString
asset name = unsafePerformIO (jsg "__galleryAssets" >>= (! name) >>= fromJSValUnchecked)
{-# NOINLINE asset #-}
-----------------------------------------------------------------------------
-- | How many cards the waterfall renders. The tutorial repeats its 15-image
-- sub-array five times (75 cards), which is what makes the auto-scroll feel
-- continuous; we do the same by cycling 'pics'.
galleryCount :: Int
galleryCount = length pics * 5
-----------------------------------------------------------------------------
-- | The tutorial's exact furniture images: intrinsic @(width, height)@ of
-- @assets\/furnitures\/0.png@ .. @14.png@, verbatim from the official
-- @furnituresPictures.tsx@ so the waterfall lays out identically.
pics :: [(Int, Int)]
pics =
  [ (512,429),  (511,437),  (1024,1589), (510,418), (509,438)
  , (1024,1557),(509,415),  (509,426),   (1024,1544),(510,432)
  , (1024,1467),(1024,1545),(512,416),   (1024,1509),(512,411)
  ]
-----------------------------------------------------------------------------
-- | Index into the 15 base images for card @i@ (wraps around).
picIndex :: Int -> Int
picIndex i = i `mod` length pics
-----------------------------------------------------------------------------
-- | @data:@ URI (embedded in the bundle) for card @i@'s furniture PNG.
picUrl :: Int -> MisoString
picUrl i = asset ("furnitures/" <> (ms (picIndex i)) <> ".png")
-----------------------------------------------------------------------------
picAspect :: Int -> MisoString
picAspect i = ms w <> " / " <> ms h
  where (w, h) = pics Prelude.!! picIndex i
-----------------------------------------------------------------------------
