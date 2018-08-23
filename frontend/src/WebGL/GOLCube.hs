{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes        #-}
{-# LANGUAGE RecursiveDo       #-}
{-# LANGUAGE TypeFamilies      #-}
module WebGL.GOLCube
  ( golCube
  ) where

import           Control.Lens                        (Lens', traverseOf, (+~),
                                                      (-~), (^.), (^?),
                                                      _Wrapped)
import           Control.Monad                       ((>=>))
import           Control.Monad.Except                (runExceptT)

import           Data.Bits                           ((.|.))
import           Data.Bool                           (bool)
import           Data.Function                       ((&))
import           Data.Semigroup                      ((<>))
import           System.Random                       (StdGen)

import           Reflex                              (Dynamic, Event, (<@),
                                                      (<@>))
import qualified Reflex                              as R
import           Reflex.Dom.Core                     (DomRenderHook,
                                                      MonadWidget, Widget, (=:))
import qualified Reflex.Dom.Core                     as RD

import qualified Linear                              as L
import           Linear.Matrix                       ((!*!))
import qualified Linear.Matrix                       as LM
import           Linear.V3                           (V3 (..))

import qualified Linear.Projection                   as LP
import qualified Linear.Quaternion                   as Q

import           GHCJS.DOM.Types                     (Float32Array (..),
                                                      GLsizei, JSM, MonadJSM,
                                                      WebGLProgram,
                                                      WebGLRenderingContext,
                                                      WebGLTexture, liftJSM)
import qualified GHCJS.DOM.WebGLRenderingContextBase as Gl

import           Reflex.Dom.CanvasBuilder.Types      (CanvasConfig (..),
                                                      CanvasInfo (..))
import qualified Reflex.Dom.CanvasDyn                as C

import qualified Styling.Bootstrap                   as B

import           Internal                            (tshow, (<$$), (<$$>))
import           WebGL.GOL                           as GOL
import           WebGL.Internal                      as GI
import qualified WebGL.Shaders.GOLCube               as Shaders
import           WebGL.Statics                       (cubePositions, indices,
                                                      wrappedTex)
import           WebGL.Types                         (CubeInfo (CubeInfo),
                                                      CubeRotation (..), Error,
                                                      GOL (..), GOLCube (..),
                                                      HasCubeInfo (..),
                                                      HasGOL (..),
                                                      HasGOLCube (..), liftGLM,
                                                      runWebGLM)

-- |
-- Rework of the example at <https://github.com/mdn/webgl-examples/blob/gh-pages/tutorial/sample6/webgl-demo.js Textured Cube Example>

fov,zNear,zFar :: Double
fov = 45 * (pi / 180)
zNear = 0.1
zFar = 100.0

projectionMatrix :: Double -> LM.M44 Double
projectionMatrix aspect = LP.perspective fov aspect zNear zFar

modelViewMatrix :: LM.M44 Double
modelViewMatrix = LM.identity

golCubeDraw
  :: MonadJSM m
  => V3 Double
  -> WebGLRenderingContext
  -> GOLCube
  -> m GOLCube
golCubeDraw = drawScene
  GOL.width
  GOL.height
  golFront
  golCubeProgram
  golCubeProjMatPrimary

drawScene
  :: MonadJSM m
  => GLsizei
  -> GLsizei
  -> Lens' GOL WebGLTexture
  -> Lens' GOLCube WebGLProgram
  -> Lens' GOLCube Float32Array
  -> V3 Double
  -> WebGLRenderingContext
  -> GOLCube
  -> m GOLCube
drawScene w h texL prgL projL mvVec cx g = do
  Gl.bindFramebuffer cx Gl.FRAMEBUFFER Nothing

  Gl.clearColor cx 0.0 0.0 0.0 1.0 -- Clear to black, fully opaque
  Gl.clearDepth cx 1.0             -- Clear everything
  Gl.enable cx Gl.DEPTH_TEST       -- Enable depth testing
  Gl.depthFunc cx Gl.LEQUAL        -- Near things obscure far things
  Gl.clear cx (Gl.COLOR_BUFFER_BIT .|. Gl.DEPTH_BUFFER_BIT) -- Clear the canvas before we start drawing on it.
  let
    cubeRot = g ^. golCubeCubeRotation . _Wrapped
    tVector = mvVec + V3 (-0.0) 0.0 (-4.0)
    zRotate = Q.axisAngle (V3 0 0 1) cubeRot
    xRotate = Q.axisAngle (V3 1 0 0) (cubeRot * 0.7)

    mvMat = modelViewMatrix
      !*! LM.mkTransformation zRotate tVector
      !*! LM.mkTransformation xRotate tVector

  -- Tell WebGL how to find the vertices of our cube from the position buffer
  GI.attrib "aVertexPosition" (g ^. golCubeSqBuffer) 3 Nothing prgL g cx
  GI.attrib "aTextureCoord" (g ^. golCubeTxBuffer) 2 Nothing prgL g cx

  Gl.bindBuffer cx Gl.ELEMENT_ARRAY_BUFFER (g ^? golCubeIxBuffer)

  Gl.useProgram cx (g ^? prgL)

  mvMat32Array <- GI.matToF32Array mvMat
  GI.uniformMatrix4fv "uModelViewMatrix" mvMat32Array prgL g cx
  GI.uniformMatrix4fv "uProjectionMatrix" (g ^. projL) prgL g cx

  GI.uniformI "state" (0::Int) prgL g cx

  Gl.activeTexture cx Gl.TEXTURE0
  Gl.bindTexture cx Gl.TEXTURE_2D (g ^? golCubeGOL . texL)

  Gl.viewport cx 0 0 w h
  let
    vertCount = 36
    vType     = Gl.UNSIGNED_SHORT
    vOffset   = 0

  Gl.drawElements cx Gl.TRIANGLES vertCount vType vOffset

  pure (g & golCubeCubeRotation . _Wrapped +~ 0.1)

createGOLCube
  :: MonadJSM m
  => WebGLRenderingContext
  -> m (Either Error GOLCube)
createGOLCube cx = liftJSM . runExceptT . runWebGLM $
  GOL.createGOL cx >>= liftGLM >>= f
  where
    f g = GOLCube <$> pure g
      <*> GI.initProgram Shaders.golCubeVertSrc Shaders.golCubeFragSrc cx
      <*> GI.createBuffer cubePositions GI.toFloat32Array cx
      <*> GI.createBuffer wrappedTex GI.toFloat32Array cx
      <*> GI.createBufferType Gl.ELEMENT_ARRAY_BUFFER indices GI.toUint16Array cx
      <*> GI.matToF32Array (projectionMatrix primAspect)
      <*> GI.matToF32Array (projectionMatrix texAspect)
      <*> pure (CubeRot 0.0)

    primAspect = GOL.width / GOL.height
    texAspect = fromIntegral GOL.scaledWidth / fromIntegral GOL.scaledHeight

initCube
  :: MonadWidget t m
  => m (CubeInfo t)
initCube = do
  ePost <- RD.getPostBuild
  eTick <- () <$$ RD.tickLossyFromPostBuildTime 0.1

  eReset      <- B.bsButton_ "Reset" B.Primary
  eStep       <- B.bsButton_ "Step" B.Primary
  eToggleAnim <- B.bsButton_ "Toggle Animation" B.Primary

  dTick <- bool eStep eTick <$$> R.toggle False eToggleAnim

  (_, (canvas, _)) <- RD.elAttr' "div" ("class" =: "canvas-wrapper")
    $ RD.elAttr' "canvas"
    ( "height" =: tshow (height :: Int) <>
      "width"  =: tshow (width :: Int) <>
      "class"  =: "gol-canvas"
    )
    RD.blank

  dCx <- _canvasInfo_context <$$> C.dContextWebgl (CanvasConfig canvas [])

  eForward  <- (L._z -~ 1.0) <$$ B.bsButton_ "Zoom Out" B.Primary
  eBackward <- (L._z +~ 1.0) <$$ B.bsButton_ "Zoom In" B.Primary
  eRight    <- (L._x +~ 1.0) <$$ B.bsButton_ "Slide Right" B.Primary
  eLeft     <- (L._x -~ 1.0) <$$ B.bsButton_ "Slide Left" B.Primary

  pure $ CubeInfo
    dCx
    eReset
    dTick
    eToggleAnim
    ePost
    eForward
    eBackward
    eRight
    eLeft

runGL'
  :: ( MonadWidget t m
     , DomRenderHook t m
     , Traversable g
     )
  => Dynamic t (V3 Double)
  -> Dynamic t WebGLRenderingContext
  -> Dynamic t (g GOLCube)
  -> (WebGLRenderingContext -> GOL -> JSM GOL)
  -> Event t a
  -> m (Event t (g GOLCube))
runGL' dMvVec dCx dMGol f eGo = RD.requestDomAction $
  R.current (f' <$> dMvVec <*> dCx <*> dMGol) <@ eGo
  where
    f' mv cx = traverse (traverseOf golCubeGOL (f cx) >=> golCubeDraw mv cx)

golCube :: StdGen -> Widget x ()
golCube sGen = RD.divClass "gol-cube" $ do
  cI <- initCube
  let
    dCx = cI ^. cubeInfoCx

    noMove = V3 0 0 0

    eMoves = [ cI ^. cubeInfoUpPress
             , cI ^. cubeInfoDownPress
             , cI ^. cubeInfoRightPress
             , cI ^. cubeInfoLeftPress
             ]

  dMvVec <- R.foldDyn ($) noMove $ R.mergeWith (.) eMoves

  (eError, eGol) <- R.fanEither <$$> RD.requestDomAction $
    R.current (createGOLCube <$> dCx) <@ (cI ^. cubeInfoPost)

  eInitialDraw <- RD.requestDomAction $
    (\c g -> do
        _ <- GOL.setInitialState sGen c (g ^. golCubeGOL)
        golCubeDraw noMove c g
    )
    <$> R.current dCx
    <@> eGol

  let
    dDraw = pure (\mv cx mgol -> traverse (golCubeDraw mv cx) mgol)

  rec dMGol <- R.holdDyn Nothing $ R.leftmost
        [ pure <$> eGol
        , eWasReset
        , eStepRendered
        , eMoved
        ]

      eMoved <- RD.requestDomAction $
        R.current (dDraw <*> dMvVec <*> dCx <*> dMGol) <@ foldMap (() <$) eMoves

      eWasReset <- runGL' dMvVec dCx dMGol (GOL.setInitialState sGen)
        $ cI ^. cubeInfoReset

      eStepRendered <- runGL' dMvVec dCx dMGol GOL.stepRenderCopyTexture . R.switchDyn
        $ cI ^. cubeInfoTick

  dStatus <- R.holdDyn "Game Not Ready" $ R.leftmost
    [ ("Bugger: " <>) . tshow <$> eError
    , "Woot!" <$ eGol
    ]

  dRendered <- R.holdDyn "Nothing Rendered" $
    ("Rendered!" <$ eInitialDraw) <>
    ("Stepped!"  <$ eStepRendered)

  RD.display dMvVec

  RD.divClass "status" (RD.dynText dStatus)
  RD.divClass "rendered" (RD.dynText dRendered)
