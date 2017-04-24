{-# LANGUAGE PatternSynonyms #-}
module Simula.NewCompositor.SceneGraph.Wayland where

import Control.Lens
import Control.Monad
import Data.IORef
import Data.Int
import Data.Typeable
import Data.Word
import Linear
import Linear.OpenGL

import Graphics.Rendering.OpenGL hiding (scale, Plane)
import Graphics.GL (glEnable, glDisable, pattern GL_DEPTH_TEST) -- workaround, probably a user error
import Foreign

import Simula.NewCompositor.Geometry
import Simula.NewCompositor.Utils
import Simula.NewCompositor.OpenGL
import Simula.NewCompositor.SceneGraph
import Simula.NewCompositor.Types
import Simula.NewCompositor.Wayland.Output

data BaseWaylandSurfaceNode = BaseWaylandSurfaceNode {
  _waylandSurfaceNodeBase :: BaseDrawable,
  _waylandSurfaceNodeSurface :: IORef (Some WaylandSurface),
  _waylandSurfaceNodeSurfaceTransform :: IORef (M44 Float),
  _waylandSurfaceNodeDecorations :: WireframeNode,
  _waylandSurfaceNodeTextureCoords :: BufferObject,
  _waylandSurfaceNodeVertexCoords :: BufferObject,
  _waylandSurfaceNodeShader :: Program,
  _waylandSurfaceNodeAPosition, _waylandSurfaceNodeATexCoord :: AttribLocation,
  _waylandSurfaceNodeUMVPMatrix :: UniformLocation
  } deriving (Eq, Typeable)

data MotorcarSurfaceNode = MotorcarSurfaceNode {
  _motorcarSurfaceNodeBase :: BaseWaylandSurfaceNode,

  _motorcarSurfaceNodeDepthCompositedSurfaceShader :: Program,
  _motorcarSurfaceNodeDepthCompositedSurfaceBlitterShader :: Program,
  _motorcarSurfaceNodeClippingShader :: Program,
    
  _motorcarSurfaceNodeColorTextureCoords :: BufferObject,
  _motorcarSurfaceNodeDepthTextureCoords :: BufferObject,
  _motorcarSurfaceNodeSurfaceTextureCoords :: BufferObject,
  _motorcarSurfaceNodeCuboidClippingVertices :: BufferObject,
  _motorcarSurfaceNodeCuboidClippingIndices :: BufferObject,
  
  _motorcarSurfaceNodeAPositionDepthComposite:: AttribLocation,
  _motorcarSurfaceNodeAColorTexCoordDepthComposite:: AttribLocation,
  _motorcarSurfaceNodeADepthTexCoordDepthComposite:: AttribLocation,

  _motorcarSurfaceNodeAPositionBlit :: AttribLocation,
  _motorcarSurfaceNodeATexCoordBlit :: AttribLocation,
  _motorcarSurfaceNodeUColorSamplerBlit :: UniformLocation,
  _motorcarSurfaceNodeUDepthSamplerBlit :: UniformLocation,

  _motorcarSurfaceNodeAPositionClipping :: AttribLocation,
  _motorcarSurfaceNodeUMVPMatrixClipping :: UniformLocation,
  _motorcarSurfaceNodeUColorClipping :: UniformLocation,

  _motorcarSurfaceNodeDimensions :: V3 Float
  } deriving (Eq, Typeable)



makeClassy ''BaseWaylandSurfaceNode
makeClassy ''MotorcarSurfaceNode

class Drawable a => WaylandSurfaceNode a where
  computeLocalSurfaceIntersection :: a -> Ray -> IO (Maybe (V2 Float, Float))
  default computeLocalSurfaceIntersection :: HasBaseWaylandSurfaceNode a => a -> Ray -> IO (Maybe (V2 Float, Float))
  computeLocalSurfaceIntersection this ray
    | dot (ray ^. rayPos) (surfacePlane ^. planeNorm) == 0
    = return Nothing
  
    | otherwise = do
        tfRay <- (transformRay ray . inv44) <$> readIORef (this ^. waylandSurfaceNodeSurfaceTransform)
        let t = intersectPlane surfacePlane tfRay
        let intersection = solveRay tfRay t
        Some ws <- readIORef (this ^. waylandSurfaceNodeSurface)
        size <- (fmap.fmap) fromIntegral $ wsSize ws
        let coords = liftI2 (*) intersection (V3 (size ^. _x) (size ^. _y) 0)
      
        return $ if t >= 0 then Just (coords ^. _xy, t) else Nothing

    where
      surfacePlane = Plane (V3 0 0 0) (V3 0 0 1)

  computeSurfaceTransform :: a -> Float -> IO ()
  default computeSurfaceTransform :: HasBaseWaylandSurfaceNode a => a -> Float -> IO ()
  computeSurfaceTransform this ppcm = when (ppcm > 0) $ do
    let ppm = 100*ppcm
    let rotQ = axisAngle (V3 0 0 1) pi
    -- TODO test if it's identical
    let rotM = mkTransformation rotQ (V3 (negate 0.5) (negate 0.5) 0)
      
    Some surface <- readIORef (this ^. waylandSurfaceNodeSurface)
    size <- (fmap . fmap) fromIntegral $ wsSize surface
    
    let scaleM = scale identity $ V3 (negate (size ^. _x) / ppm)  ((size ^. _y) / ppm) 1
          
    writeIORef (this ^. waylandSurfaceNodeSurfaceTransform) $ scaleM !*! rotM
    
    setNodeTransform (this ^. waylandSurfaceNodeDecorations) $ scaleM !*! mkTransformation rotQ (V3 0 0 0) !*! scale identity (V3 1.04 1.04 0)

instance HasBaseSceneGraphNode BaseWaylandSurfaceNode where
  baseSceneGraphNode = baseSceneGraphNode

instance HasBaseDrawable BaseWaylandSurfaceNode where
  baseDrawable = waylandSurfaceNodeBase

instance HasBaseSceneGraphNode MotorcarSurfaceNode where
  baseSceneGraphNode = baseSceneGraphNode

instance HasBaseDrawable MotorcarSurfaceNode where
  baseDrawable = baseDrawable

instance HasBaseWaylandSurfaceNode MotorcarSurfaceNode where
  baseWaylandSurfaceNode = motorcarSurfaceNodeBase

instance SceneGraphNode BaseWaylandSurfaceNode where
  nodeOnFrameBegin this _ = do
    computeSurfaceTransform this 8
    Some surface <- readIORef $ _waylandSurfaceNodeSurface this
    wsPrepare surface
    
  nodeOnFrameDraw = drawableOnFrameDraw

  nodeIntersectWithSurfaces this ray = do
    closestSubtreeIntersection <- defaultNodeIntersectWithSurfaces this ray
    Some surface <- readIORef $ this ^. waylandSurfaceNodeSurface
    ty <- wsType surface
    case ty of
      Cursor -> return closestSubtreeIntersection
      _ -> do
        tf <- nodeTransform this
        let localRay = transformRay ray (inv44 tf)

        maybeIsec <- computeLocalSurfaceIntersection this localRay

        size <- (fmap . fmap) fromIntegral $ wsSize surface

        case (maybeIsec, closestSubtreeIntersection) of
          (Just (isec, t), Just closest)
            | isec ^. _x >= 0 && isec ^. _y >= 0
              && and (liftI2 (<=) isec size)
              && t < (closest ^. rsiT)
            -> return . Just $ RaySurfaceIntersection (Some this) isec ray t
          _ -> return closestSubtreeIntersection
                             
      

instance VirtualNode BaseWaylandSurfaceNode

instance Drawable BaseWaylandSurfaceNode where
  drawableDraw this scene display = do
    Some surface <- readIORef $ _waylandSurfaceNodeSurface this
    texture <- wsTexture surface

    currentProgram $= Just (_waylandSurfaceNodeShader this)

    let aPosition = _waylandSurfaceNodeAPosition this
    let aTexCoord = _waylandSurfaceNodeATexCoord this
    let uMVPMatrix = _waylandSurfaceNodeUMVPMatrix this
    let vertexCoords = _waylandSurfaceNodeVertexCoords this
    let textureCoords = _waylandSurfaceNodeTextureCoords this
    
    vertexAttribArray aPosition $= Enabled
    bindBuffer ArrayBuffer $= Just vertexCoords
    vertexAttribPointer aPosition $= (ToFloat, VertexArrayDescriptor 3 Float 0 nullPtr)

    vertexAttribArray aTexCoord $= Enabled
    bindBuffer ArrayBuffer $= Just textureCoords
    vertexAttribPointer aTexCoord $= (ToFloat, VertexArrayDescriptor 2 Float 0 nullPtr)

    textureBinding Texture2D $= Just texture
    textureFilter Texture2D $= ((Linear', Nothing), Linear')

    surfaceTf <- readIORef $ _waylandSurfaceNodeSurfaceTransform this
    viewpoints <- readIORef $ _displayViewpoints display
    forM_ viewpoints $ \vp -> do
      --TODO compare w/ order in draw for WireFrameNode 
      port <- readIORef (vp ^. viewPointViewPort)
      setViewPort port
      
      projMatrix <- readIORef (vp ^. viewPointProjectionMatrix)
      viewMatrix <- readIORef (vp ^. viewPointViewMatrix)
      worldTf <- nodeWorldTransform this
    
      let mat = (projMatrix !*! viewMatrix !*! worldTf !*! surfaceTf) ^. m44GLmatrix
      uniform uMVPMatrix $= mat
      drawArrays TriangleFan 0 4

    textureBinding Texture2D $= Nothing
    vertexAttribArray aPosition $= Disabled
    vertexAttribArray aTexCoord $= Disabled
    currentProgram $= Nothing

instance WaylandSurfaceNode BaseWaylandSurfaceNode

instance SceneGraphNode MotorcarSurfaceNode where
  nodeOnWorldTransformChange this scene = sendTransformToClient this

instance VirtualNode MotorcarSurfaceNode

instance Drawable MotorcarSurfaceNode where
  drawableDraw this scene display = do
    stencilTest $= Enabled
    bindFramebuffer DrawFramebuffer $= display ^. displayScratchFrameBuffer
    clearColor $= Color4 0 0 0 0
    clearDepth $= 1
    clearStencil $= 0
    stencilMask $= 0xff
    clear [ColorBuffer, DepthBuffer, StencilBuffer]

    drawWindowBoundsStencil this display

    Some surface <- readIORef (this ^. waylandSurfaceNodeSurface)
    dce <- wsDepthCompositingEnabled surface
    
    let surfaceCoords = this ^. motorcarSurfaceNodeSurfaceTextureCoords

    case dce of
      True -> do
        currentProgram $= Just (this ^. motorcarSurfaceNodeDepthCompositedSurfaceShader)
        let aPosition = this ^. motorcarSurfaceNodeAPositionDepthComposite
        let aColorTexCoord = this ^. motorcarSurfaceNodeAColorTexCoordDepthComposite
        let aDepthTexCoord = this ^. motorcarSurfaceNodeADepthTexCoordDepthComposite

        vertexAttribArray aPosition $= Enabled
        bindBuffer ArrayBuffer $= Just surfaceCoords
        vertexAttribPointer aPosition $= (ToFloat, VertexArrayDescriptor 3 Float 0 nullPtr)
  
        vertexAttribArray aColorTexCoord $= Enabled
        bindBuffer ArrayBuffer $= Nothing
        vertexAttribArray aDepthTexCoord $= Enabled
        bindBuffer ArrayBuffer $= Nothing
      _ -> do
        currentProgram $= Just (this ^. waylandSurfaceNodeShader)
        let aPosition = this ^. waylandSurfaceNodeAPosition
        let aTexCoord = this ^. waylandSurfaceNodeATexCoord
        let uMVPMatrix = this ^. waylandSurfaceNodeUMVPMatrix

        vertexAttribArray aPosition $= Enabled
        bindBuffer ArrayBuffer $= Just surfaceCoords
        vertexAttribPointer aPosition $= (ToFloat, VertexArrayDescriptor 3 Float 0 nullPtr)

        vertexAttribArray aTexCoord $= Enabled
        bindBuffer ArrayBuffer $= Nothing
        uniform uMVPMatrix $= (identity ^. m44GLmatrix :: GLmatrix Float)
        glDisable GL_DEPTH_TEST
        depthMask $= Disabled
        
    tex <- wsTexture surface
    textureBinding Texture2D $= Just tex
    textureFilter Texture2D $= ( (Nearest, Nothing), Nearest )

    vps <- readIORef (display ^. displayViewpoints)

    forM_ vps $ \vp -> do
      readIORef (vp ^. viewPointViewPort) >>= setViewPort
      case dce of
        True -> do
          ccvp <- readIORef (vp ^. viewPointClientColorViewPort)
          ccvpCoords <- vpCoords ccvp
          let aColorTexCoord = this ^. motorcarSurfaceNodeAColorTexCoordDepthComposite
          
          withArrayLen ccvpCoords $ \len coordPtr ->
            vertexAttribPointer aColorTexCoord $= (ToFloat, VertexArrayDescriptor 2 Float 0 coordPtr)

          cdvp <- readIORef (vp ^. viewPointClientDepthViewPort)
          cdvpCoords <- vpCoords cdvp
          let aDepthTexCoord = this ^. motorcarSurfaceNodeADepthTexCoordDepthComposite
          
          withArrayLen cdvpCoords $ \len coordPtr ->
            vertexAttribPointer aDepthTexCoord $= (ToFloat, VertexArrayDescriptor 2 Float 0 coordPtr)
        False -> do
          vport <- readIORef (vp ^. viewPointViewPort)
          vportCoords <- vpCoords vport
          let aTexCoord = this ^. waylandSurfaceNodeATexCoord
          
          withArrayLen vportCoords $ \len coordPtr ->
            vertexAttribPointer aTexCoord $= (ToFloat, VertexArrayDescriptor 2 Float 0 coordPtr)
      drawArrays TriangleFan 0 4

    when (not dce) $ do
      glEnable GL_DEPTH_TEST
      depthMask $= Enabled

    clipWindowBounds this display
    drawFrameBufferContents this display

    bindFramebuffer Framebuffer $= defaultFramebufferObject
    vertexAttribArray (this ^. motorcarSurfaceNodeAPositionDepthComposite) $= Disabled
    vertexAttribArray (this ^. motorcarSurfaceNodeAColorTexCoordDepthComposite) $= Disabled
    activeTexture $= TextureUnit 1
    textureBinding Texture2D $= Nothing
  
    activeTexture $= TextureUnit 0
    textureBinding Texture2D $= Nothing
  
    currentProgram $= Nothing
    stencilTest $= Disabled
  
      where
        vpCoords :: ViewPort -> IO [Float]
        vpCoords vp = do
          vpOffset <- readIORef (vp ^. viewPortOffset)
          vpSize <- readIORef (vp ^. viewPortSize)
          return $ [ vpOffset ^. _x, 1 - vpOffset ^. _y
                   , vpOffset ^. _x + vpSize ^. _x, 1 - vpOffset ^. _y
                   , vpOffset ^. _x + vpSize ^. _x, 1 - vpOffset ^. _y - vpSize ^. _y
                   , vpOffset ^. _x, 1 - vpOffset ^. _y - vpSize ^. _y ]

        drawWindowBoundsStencil this display = do
          colorMask $= Color4 Disabled Disabled Disabled Disabled
          depthMask $= Disabled
          stencilFunc $= (Never, 1, 0xff)
          stencilOp $= (OpReplace, OpKeep, OpKeep)

          currentProgram $= Just (this ^. motorcarSurfaceNodeClippingShader)
          let aPosition = this ^. motorcarSurfaceNodeAPositionClipping
          let uMVPMatrix = this ^. motorcarSurfaceNodeUMVPMatrixClipping
          let uColor = this ^. motorcarSurfaceNodeUColorClipping

          vertexAttribArray aPosition $= Enabled
          bindBuffer ArrayBuffer $= Just (this ^. motorcarSurfaceNodeCuboidClippingVertices)
          vertexAttribPointer aPosition $= (ToFloat, VertexArrayDescriptor 3 Float 0 nullPtr)

          uniform uColor $= (Color3 1 1 0 :: Color3 Float)

          bindBuffer ElementArrayBuffer $= Just (this ^. motorcarSurfaceNodeCuboidClippingIndices)

          wt <- nodeWorldTransform this
          let modelMat = wt !*! scale identity (this ^. motorcarSurfaceNodeDimensions)

          vps <- readIORef (display ^. displayViewpoints)
          forM_ vps $ \vp -> do
            port <- readIORef (vp ^. viewPointViewPort)
            setViewPort port

            projMatrix <- readIORef (vp ^. viewPointProjectionMatrix)
            viewMatrix <- readIORef (vp ^. viewPointViewMatrix)
            let mvp = (projMatrix !*! viewMatrix !*! modelMat) ^. m44GLmatrix
            uniform uMVPMatrix $= mvp
            let numElements = 36 --TODO eliminate this
            drawElements Triangles numElements UnsignedInt nullPtr
  
          vertexAttribArray aPosition $= Disabled
          currentProgram $= Nothing
          colorMask $= Color4 Enabled Enabled Enabled Enabled
          depthMask $= Enabled
          stencilMask $= 0
          stencilFunc $= (Equal, 1, 0xff)

        clipWindowBounds :: MotorcarSurfaceNode -> Display -> IO ()
        clipWindowBounds this display = do
          colorMask $= Color4 Disabled Disabled Disabled Disabled
          depthMask $= Disabled
          stencilMask $= 0xff
          stencilFunc $= (Always, 0, 0xff)
          stencilOp $= (OpKeep, OpKeep, OpReplace)

          currentProgram $= Just (this ^. motorcarSurfaceNodeClippingShader)
          let aPosition = this ^. motorcarSurfaceNodeAPositionClipping
          let uMVPMatrix = this ^. motorcarSurfaceNodeUMVPMatrixClipping
          let uColor = this ^. motorcarSurfaceNodeUColorClipping

          vertexAttribArray aPosition $= Enabled
          bindBuffer ArrayBuffer $= Just (this ^. motorcarSurfaceNodeCuboidClippingVertices)
          vertexAttribPointer aPosition $= (ToFloat, VertexArrayDescriptor 3 Float 0 nullPtr)

          uniform uColor $= (Color3 1 0 0 :: Color3 Float)

          bindBuffer ElementArrayBuffer $= Just (this ^. motorcarSurfaceNodeCuboidClippingIndices)

          wt <- nodeWorldTransform this
          let modelMat = wt !*! scale identity (this ^. motorcarSurfaceNodeDimensions)

          vps <- readIORef (display ^. displayViewpoints)
          
          Some surface <- readIORef (this ^. waylandSurfaceNodeSurface)
          cmode <- wsClippingMode surface
          dce <- wsDepthCompositingEnabled surface

          when (cmode == Cuboid && dce) $ do
            cullFace $= Just Front
            forM_ vps $ \vp -> do
              port <- readIORef (vp ^. viewPointViewPort)
              setViewPort port
              
              projMatrix <- readIORef (vp ^. viewPointProjectionMatrix)
              viewMatrix <- readIORef (vp ^. viewPointViewMatrix)

              let mvp = (projMatrix !*! viewMatrix !*! modelMat) ^. m44GLmatrix
              uniform uMVPMatrix $= mvp
              let numElements = 36
              drawElements Triangles numElements UnsignedInt nullPtr
              
            cullFace $= Just Back

          if dce
            then depthFunc $= Just Greater
            else depthMask $= Enabled >> stencilMask $= 0
            
          forM_ vps $ \vp -> do
            port <- readIORef (vp ^. viewPointViewPort)
            setViewPort port
            
            projMatrix <- readIORef (vp ^. viewPointProjectionMatrix)
            viewMatrix <- readIORef (vp ^. viewPointViewMatrix)

            let mvp = (projMatrix !*! viewMatrix !*! modelMat) ^. m44GLmatrix
            uniform uMVPMatrix $= mvp
            let numElements = 36
            drawElements Triangles numElements UnsignedInt nullPtr

          depthFunc $= Just Less
          vertexAttribArray aPosition $= Disabled
          currentProgram $= Nothing
          colorMask $= Color4 Enabled Enabled Enabled Enabled
          depthMask $= Enabled
          stencilMask $= 0
          stencilFunc $= (Equal, 1, 0xff)
          
        drawFrameBufferContents this display = do
          depthFunc $= Just Lequal
          bindFramebuffer DrawFramebuffer $= defaultFramebufferObject
          bindFramebuffer ReadFramebuffer $= display ^. displayScratchFrameBuffer
          stencilMask $= 0xff

          res <- displaySize display
          let s0 = Position 0 0
          let s1 = Position (fromIntegral $ res ^. _x - 1) (fromIntegral $ res ^. _y - 1)
          blitFramebuffer s0 s1 s0 s1 [StencilBuffer'] Nearest

          stencilMask $= 0
          stencilFunc $= (Equal, 1, 0xff)

          currentProgram $= Just (this ^. motorcarSurfaceNodeDepthCompositedSurfaceBlitterShader)
          
          activeTexture $= TextureUnit 0
          texture Texture2D $= Enabled
          textureBinding Texture2D $= Just (display ^. displayScratchColorBufferTexture)
          textureFilter Texture2D $= ( (Nearest, Nothing), Nearest )

          activeTexture $= TextureUnit 1
          texture Texture2D $= Enabled
          textureBinding Texture2D $= Just (display ^. displayScratchDepthBufferTexture)
          textureFilter Texture2D $= ( (Nearest, Nothing), Nearest )

          let aPosition = this ^. motorcarSurfaceNodeAPositionBlit
          let aTexCoord = this ^. motorcarSurfaceNodeATexCoordBlit
          let surfaceCoords = this ^. motorcarSurfaceNodeSurfaceTextureCoords

          vertexAttribArray aPosition $= Enabled
          bindBuffer ArrayBuffer $= Just surfaceCoords
          vertexAttribPointer aPosition $= (ToFloat, VertexArrayDescriptor 3 Float 0 nullPtr)
          vertexAttribArray aTexCoord $= Enabled
          bindBuffer ArrayBuffer $= Nothing

          vps <- readIORef (display ^. displayViewpoints)
          forM_ vps $ \vp -> do
            vport <- readIORef (vp ^. viewPointViewPort)
            setViewPort vport
            
            vpOffset <- readIORef (vport ^. viewPortOffset)
            vpSize <- readIORef (vport ^. viewPortSize)
            let textureBlitCoords = [ vpOffset ^. _x, vpOffset ^. _y
                                    , vpOffset ^. _x + vpSize ^. _x, vpOffset ^. _y
                                    , vpOffset ^. _x + vpSize ^. _x, vpOffset ^. _y + vpSize  ^. _y
                                    , vpOffset ^. _x, vpOffset ^. _y + vpSize ^. _y ] :: [Float]

            withArrayLen textureBlitCoords $ \len coordPtr ->
              vertexAttribPointer aTexCoord $= (ToFloat, VertexArrayDescriptor 2 Float 0 coordPtr)

            drawArrays TriangleFan 0 4
     
      

instance WaylandSurfaceNode MotorcarSurfaceNode where
  computeLocalSurfaceIntersection this ray | t >= 0 = return $ Just (V2 0 0, t)
                                           | otherwise = return Nothing
    where
      box = AxisAlignedBox (this ^. motorcarSurfaceNodeDimensions)
      t = intersectBox box ray 0 100
  
  computeSurfaceTransform this ppcm = writeIORef (this ^. baseWaylandSurfaceNode.waylandSurfaceNodeSurfaceTransform) identity

newWaylandSurfaceNode :: (WaylandSurface ws, SceneGraphNode a) => ws -> a -> M44 Float -> IO BaseWaylandSurfaceNode
newWaylandSurfaceNode ws parent tf = do
  program <- getProgram ShaderMotorcarSurface

  texCoords <- genObjectName
  bindBuffer ArrayBuffer $= Just texCoords
  withArrayLen textureCoordinates $ \len coordPtr ->
    bufferData ArrayBuffer $= (fromIntegral (len * sizeOf (undefined :: Float)), coordPtr, StaticDraw)
  
  verCoords <- genObjectName
  bindBuffer ArrayBuffer $= Just verCoords
  withArrayLen vertexCoordinates $ \len coordPtr ->
    bufferData ArrayBuffer $= (fromIntegral (len * sizeOf (undefined :: Float)), coordPtr, StaticDraw)

  aPos <- get $ attribLocation program "aPosition"
  aTex <- get $ attribLocation program "aTexCoord"
  uMVP <- get $ uniformLocation program "uMVPMatrix"

  let decoVert = concat [ mkDeco i j k | i <- [-1,1], j <- [-1,1], k <- [-1,1] ]
  let decoColor = Color3 0.5 0.5 0.5

  rec decoNode <- newWireframeNode decoVert decoColor node identity
      node <- BaseWaylandSurfaceNode
              <$> newBaseDrawable (Just (Some parent)) tf
              <*> newIORef (Some ws)
              <*> newIORef identity
              <*> pure decoNode
              <*> pure texCoords
              <*> pure verCoords
              <*> pure program
              <*> pure aPos
              <*> pure aTex
              <*> pure uMVP
  return node

  where
    textureCoordinates :: [Float]
    textureCoordinates = [0, 0, 0, 1, 1, 1, 1, 0]

    vertexCoordinates :: [Float]
    vertexCoordinates = [0, 0, 0, 0, 1, 0, 1, 1, 0, 1, 0, 0]

    mkDeco i j k =
      let direction = V3 i j k
          corner = direction ^* 0.5 :: V3 Float
      in concatMap (mkVertices corner direction) [ex, ey, ez]

    mkVertices corner@(V3 cx cy cz) direction (E coord) =
      let V3 sx sy sz = corner & coord -~ (direction ^. coord)
      in [cx, cy, cz, sx, sy, sz]



newMotorcarSurfaceNode :: (WaylandSurface ws, SceneGraphNode a) => ws -> a -> M44 Float -> V3 Float -> IO MotorcarSurfaceNode
newMotorcarSurfaceNode ws prt tf dims = do
  wsn <- newWaylandSurfaceNode ws prt tf
  dcss <- getProgram ShaderDepthCompositedSurface
  dcsbs <-  getProgram ShaderDepthCompositedSurfaceBlitter
  clipping <- getProgram ShaderMotorcarLine

  surfaceTexCoords <- genObjectName
  bindBuffer ArrayBuffer $= Just surfaceTexCoords
  --TODO make this into an utility function
  withArrayLen surfaceVerts $ \len coordPtr ->
    bufferData ArrayBuffer $= (fromIntegral (len * sizeOf (undefined :: Float)), coordPtr, StaticDraw)

  currentProgram $= Just dcsbs
  colorSamplerBlit <- get $ uniformLocation dcsbs "uColorSampler"
  depthSamplerBlit <- get $ uniformLocation dcsbs "uDepthSampler"
  uniform colorSamplerBlit $= TextureUnit 0
  uniform depthSamplerBlit $= TextureUnit 1
  currentProgram $= Nothing

  ccv <- genObjectName
  bindBuffer ArrayBuffer $= Just ccv
  withArrayLen cuboidClippingVerts $ \len coordPtr ->
    bufferData ArrayBuffer $= (fromIntegral (len * sizeOf (undefined :: Word32)), coordPtr, StaticDraw)


  cci <- genObjectName
  bindBuffer ArrayBuffer $= Just cci
  withArrayLen cuboidClippingInds $ \len coordPtr ->
    bufferData ElementArrayBuffer $= (fromIntegral (len * sizeOf (undefined :: Float)), coordPtr, StaticDraw)

  {-
    wl_array_init(&m_dimensionsArray);
    wl_array_init(&m_transformArray);

    wl_array_add(&m_dimensionsArray, sizeof(glm::vec3));
    wl_array_add(&m_transformArray, sizeof(glm::mat4));
  -}
  
  setNodeTransform (wsn ^. waylandSurfaceNodeDecorations) $ scale identity dims

  MotorcarSurfaceNode
    <$> pure wsn

    <*> pure dcss
    <*> pure dcsbs

    <*> pure clipping
    <*> genObjectName
    <*> genObjectName
    <*> pure surfaceTexCoords
    <*> pure ccv
    <*> pure cci

    <*> get (attribLocation dcss "aPosition")
    <*> get (attribLocation dcss "aColorTexCoord")
    <*> get (attribLocation dcss "aDepthTexCoord")

    <*> get (attribLocation dcsbs "aPosition")
    <*> get (attribLocation dcsbs "aTexCoord")
    <*> pure colorSamplerBlit
    <*> pure depthSamplerBlit

    <*> get (attribLocation clipping "aPosition")
    <*> get (uniformLocation clipping "uMVPMatrix")
    <*> get (uniformLocation clipping "uColor")

    <*> pure dims
    
    
  where
    surfaceVerts = [-1, -1, 0, 1, -1, 0, 1, 1, 0, -1, 1, 0] :: [Float]
    cuboidClippingVerts = [ 0.5, 0.5, 0.5, 0.5, 0.5,-0.5
                          , 0.5,-0.5, 0.5, 0.5,-0.5,-0.5
                          ,-0.5, 0.5, 0.5,-0.5, 0.5,-0.5
                          ,-0.5,-0.5, 0.5,-0.5,-0.5,-0.5
                          ] :: [Float]
    cuboidClippingInds = [0,2,1,1,2,3,4,5,6,5,7,6,0,1,4,1,5,4,2,6,3,3,6,7,0,4,2,2,4,6,1,3,5,3,7,5] :: [Word32]
    

sendTransformToClient :: MotorcarSurfaceNode -> IO ()
sendTransformToClient = undefined
