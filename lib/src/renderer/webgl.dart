// Copyright (c) 2016, Herman Bergwerf. All rights reserved.
// Use of this source code is governed by an AGPL-3.0-style license
// that can be found in the LICENSE file.

part of bromium_webgl_renderer;

class BromiumWebGLRenderer {
  /// Backend engine that is used to retrieve the particle information.
  BromiumEngine _engine;

  /// Output canvas
  CanvasElement _canvas;

  /// Viewport dimensions
  int _viewportWidth, _viewportHeight;

  // Vertex and color buffers for each membrane (faces and wireframe).
  List<Tuple2<Buffer, Buffer>> _membranes = new List<Tuple2<Buffer, Buffer>>();

  /// WebGL context
  gl.RenderingContext _gl;

  /// Vertex and color buffers for the particle system.
  Buffer _particleSystem;

  /// Main shader
  Shader _shader;

  /// View matrix
  Matrix4 _viewMatrix;

  /// Scene center
  Vector3 _center;

  /// Trackball
  _Trackball _trackball;

  /// Do not call [_requestFrame] in the next [render] cycle.
  bool _blockRendering = false;

  /// Update simulation data in render cycle?
  bool runSimulation = true;

  /// Use isolates for simulation computations?
  bool runInIsolate = true;

  /// Constructor
  BromiumWebGLRenderer(this._engine, this._canvas) {
    _viewportWidth = _canvas.width;
    _viewportHeight = _canvas.height;
    _gl = _canvas.getContext('webgl');

    // Set some WebGL settings.
    _gl.clearColor(0.0, 0.0, 0.0, 1.0);
    _gl.enable(gl.CULL_FACE);
    _gl.enable(gl.DEPTH_TEST);
    _gl.enable(gl.BLEND);
    _gl.cullFace(gl.FRONT);
    _gl.depthFunc(gl.LESS);
    _gl.blendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);

    // Load shaders.
    _shader = new Shader(_vsSource, _fsSource, [
      'aVertexPosition',
      'aVertexColor'
    ], [
      'uViewMatrix',
      'uRotationMatrix',
      'uZoom',
      'uTranslateX',
      'uTranslateY',
      'uTranslateZ',
      'uScaleX',
      'uScaleY',
      'uScaleZ'
    ]);
    _shader.compile(_gl);
    _shader.use(_gl);

    // Setup buffer for the particle system.
    _particleSystem = new Buffer(_gl);

    // Setup trackball.
    _trackball = new _Trackball(_canvas, 1.1);
  }

  /// Resest the camera position and zooming.
  void resetCamera(Vector3 center, double z, double depth) {
    _trackball.z = -2.0 * z;
    _center = center;
    _viewMatrix = makePerspectiveMatrix(
        radians(45.0),
        _viewportWidth / _viewportHeight,
        _engine.sim.info.space.utov(0.01),
        depth);
  }

  /// Reload membrane data from the computation engine.
  void reloadMembranes() {
    for (var m = 0; m < _engine.sim.buffer.nMembranes; m++) {
      var faceBuffer = new Buffer(_gl);
      var wireBuffer = new Buffer(_gl);

      var dims = _engine.sim.buffer.getMembraneDims(m);
      var faceVerts = computeDomainPolygon(_engine.sim.info.membranes[m], dims);
      var wireVerts =
          computeDomainWireframe(_engine.sim.info.membranes[m], dims);

      var faceColors = new Uint8List((faceVerts.length / 3).ceil() * 4);
      var wireColors = new Uint8List((wireVerts.length / 3).ceil() * 4);

      for (var i = 0; i < faceColors.length; i += 4) {
        faceColors[i + 0] = 255;
        faceColors[i + 1] = 255;
        faceColors[i + 2] = 255;
        faceColors[i + 3] =
            _engine.sim.info.membranes[m] == DomainType.box ? 0 : 64;
      }

      for (var i = 0; i < wireColors.length; i += 4) {
        wireColors[i + 0] = 255;
        wireColors[i + 1] = 255;
        wireColors[i + 2] = 255;
        wireColors[i + 3] = 255;
      }

      faceBuffer.updateFloat32(_gl, faceVerts, faceColors);
      wireBuffer.updateFloat32(_gl, wireVerts, wireColors);
      _membranes.add(new Tuple2<Buffer, Buffer>(faceBuffer, wireBuffer));
    }
  }

  /// Perform one simulation cycle and render a single frame.
  void render(double time) {
    // Update particle system.
    _particleSystem.updateUint16(
        _gl, _engine.sim.buffer.pCoords, _engine.sim.buffer.pColor);

    if (runSimulation && !runInIsolate) {
      // Run a simulation cycle on the main thread.
      _engine.cycle();
    }

    // Clear view.
    _gl.viewport(0, 0, _viewportWidth, _viewportHeight);
    _gl.clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);

    // Transform view matrix.
    //viewMatrix.translate(0.0, 0.0, _trackball.z);
    //viewMatrix.multiply(_trackball.rotationMatrix);
    //viewMatrix.translate(_center.clone()..scale(-1.0));

    // Apply view matrix.
    _gl.uniformMatrix4fv(
        _shader.uniforms['uViewMatrix'], false, _viewMatrix.storage);
    _gl.uniformMatrix4fv(_shader.uniforms['uRotationMatrix'], false,
        _trackball.rotationMatrix.storage);
    _gl.uniform1f(_shader.uniforms['uZoom'], _trackball.z);
    _gl.uniform1f(_shader.uniforms['uTranslateX'], -1 * _center.x);
    _gl.uniform1f(_shader.uniforms['uTranslateY'], -1 * _center.y);
    _gl.uniform1f(_shader.uniforms['uTranslateZ'], -1 * _center.z);
    _gl.uniform1f(_shader.uniforms['uScaleX'], 1.0);
    _gl.uniform1f(_shader.uniforms['uScaleY'], 1.0);
    _gl.uniform1f(_shader.uniforms['uScaleZ'], 1.0);

    // Draw particles.
    _particleSystem.draw(
        _gl,
        _shader.attributes['aVertexPosition'],
        _shader.attributes['aVertexColor'],
        gl.POINTS,
        0,
        _engine.sim.buffer.activeParticleCount);

    // Draw membranes.
    _membranes.forEach((Tuple2<Buffer, Buffer> b) {
      b.item1.draw(_gl, _shader.attributes['aVertexPosition'],
          _shader.attributes['aVertexColor'], gl.TRIANGLES);
      _gl.disable(gl.DEPTH_TEST);
      b.item2.draw(_gl, _shader.attributes['aVertexPosition'],
          _shader.attributes['aVertexColor'], gl.LINES);
      _gl.enable(gl.DEPTH_TEST);
    });

    // Schedule next frame.
    if (!_blockRendering) {
      this._requestFrame();
    }
  }

  /// Start rendering
  void start() {
    _blockRendering = false;
    this._requestFrame();
  }

  /// Stop rendering
  void stop() {
    _blockRendering = true;
  }

  /// Schedule a new render cycle.
  void _requestFrame() {
    window.requestAnimationFrame((num time) {
      this.render(time);
    });
  }
}
