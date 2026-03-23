import {
  HalfFloatType,
  LinearFilter,
  Mesh,
  OrthographicCamera,
  PlaneGeometry,
  RGBAFormat,
  Scene,
  ShaderMaterial,
  Uniform,
  Vector2,
  Vector3,
  Vector4,
  WebGLRenderTarget,
  WebGLRenderer
} from 'three';
import { quadVert, fluidSimFrag, blurFrag, clearFrag, copyFrag } from './shaders';

const FBO_OPTS = {
  format: RGBAFormat,
  type: HalfFloatType,
  minFilter: LinearFilter,
  magFilter: LinearFilter,
  generateMipmaps: false,
  depthBuffer: false,
  stencilBuffer: false
};

class DoubleFBO {
  rt1: WebGLRenderTarget;
  rt2: WebGLRenderTarget;

  constructor(w: number, h: number, opts: typeof FBO_OPTS) {
    this.rt1 = new WebGLRenderTarget(w, h, opts);
    this.rt2 = new WebGLRenderTarget(w, h, opts);
  }

  get read() { return this.rt1; }
  get write() { return this.rt2; }

  swap() {
    const tmp = this.rt1;
    this.rt1 = this.rt2;
    this.rt2 = tmp;
  }

  setSize(w: number, h: number) {
    this.rt1.setSize(w, h);
    this.rt2.setSize(w, h);
  }

  dispose() {
    this.rt1.dispose();
    this.rt2.dispose();
  }
}

export interface FluidConfig {
  accelDissipation?: number;
  pushStrength?: number;
  curlScale?: number;
  curlStrength?: number;
  dissipations?: Vector3;
}

export default class FluidSim {
  renderer: WebGLRenderer;
  texelSize: Vector2;

  _scene: Scene;
  _camera: OrthographicCamera;
  _quad: Mesh;
  _paint: DoubleFBO | null = null;
  _lowPaint: WebGLRenderTarget | null = null;
  _lowPaintBlur: WebGLRenderTarget | null = null;
  _firstUpdate = true;
  _idleFrames = 0;
  _blurDir: Vector2;
  _drawFrom: Vector4;
  _drawTo: Vector4;
  _vel: Vector2;
  _material: ShaderMaterial;
  _copyMaterial: ShaderMaterial;
  _blurMaterial: ShaderMaterial;
  _clearMaterial: ShaderMaterial;

  static IDLE_THRESHOLD = 300;

  constructor(renderer: WebGLRenderer) {
    this.renderer = renderer;
    this._scene = new Scene();
    this._camera = new OrthographicCamera(-1, 1, 1, -1, 0, 1);
    this._quad = new Mesh(new PlaneGeometry(2, 2));
    this._scene.add(this._quad);

    this.texelSize = new Vector2();
    this._blurDir = new Vector2();
    this._drawFrom = new Vector4();
    this._drawTo = new Vector4();
    this._vel = new Vector2();

    this._material = new ShaderMaterial({
      vertexShader: quadVert,
      fragmentShader: fluidSimFrag,
      uniforms: {
        u_prevPaintTexture: new Uniform(null),
        u_lowPaintTexture: new Uniform(null),
        u_paintTexelSize: new Uniform(this.texelSize),
        u_drawFrom: new Uniform(this._drawFrom),
        u_drawTo: new Uniform(this._drawTo),
        u_pushStrength: new Uniform(25),
        u_vel: new Uniform(this._vel),
        u_dissipations: new Uniform(new Vector3(0.985, 0.985, 0.5)),
        u_curlScale: new Uniform(0.02),
        u_curlStrength: new Uniform(3)
      }
    });

    this._copyMaterial = new ShaderMaterial({
      vertexShader: quadVert,
      fragmentShader: copyFrag,
      uniforms: { u_source: new Uniform(null) }
    });

    this._blurMaterial = new ShaderMaterial({
      vertexShader: quadVert,
      fragmentShader: blurFrag,
      uniforms: {
        u_source: new Uniform(null),
        u_direction: new Uniform(this._blurDir)
      }
    });

    this._clearMaterial = new ShaderMaterial({
      vertexShader: quadVert,
      fragmentShader: clearFrag
    });
  }

  resize(width: number, height: number) {
    const needed_w = Math.max(1, width >> 2);
    const needed_h = Math.max(1, height >> 2);

    if (this._paint) {
      const cur_w = this._paint.read.width;
      const cur_h = this._paint.read.height;
      if (
        needed_w <= cur_w && needed_h <= cur_h &&
        needed_w > (cur_w >> 1) && needed_h > (cur_h >> 1)
      ) return;
    }

    const w = Math.ceil(needed_w / 64) * 64;
    const h = Math.ceil(needed_h / 64) * 64;
    const lw = Math.max(1, Math.ceil(Math.max(1, width >> 3) / 64) * 64);
    const lh = Math.max(1, Math.ceil(Math.max(1, height >> 3) / 64) * 64);

    if (this._paint) {
      this._paint.setSize(w, h);
      this._lowPaint!.setSize(lw, lh);
      this._lowPaintBlur!.setSize(lw, lh);
    } else {
      this._paint = new DoubleFBO(w, h, FBO_OPTS);
      this._lowPaint = new WebGLRenderTarget(lw, lh, FBO_OPTS);
      this._lowPaintBlur = new WebGLRenderTarget(lw, lh, FBO_OPTS);
    }

    this.texelSize.set(1 / w, 1 / h);
    this._clear();
  }

  _clear() {
    const prev = this.renderer.getRenderTarget();
    this._quad.material = this._clearMaterial;

    this.renderer.setRenderTarget(this._paint!.read);
    this.renderer.render(this._scene, this._camera);
    this.renderer.setRenderTarget(this._paint!.write);
    this.renderer.render(this._scene, this._camera);
    this.renderer.setRenderTarget(this._lowPaint!);
    this.renderer.render(this._scene, this._camera);
    this.renderer.setRenderTarget(this._lowPaintBlur!);
    this.renderer.render(this._scene, this._camera);

    this.renderer.setRenderTarget(prev);
  }

  update(x: number, y: number, radius: number, dt: number, config: FluidConfig = {}) {
    if (!this._paint) return;

    if (radius > 0) {
      this._idleFrames = 0;
    } else {
      this._idleFrames++;
      if (this._idleFrames > FluidSim.IDLE_THRESHOLD) return;
    }

    const w = this._paint.read.width;
    const h = this._paint.read.height;

    this._drawFrom.copy(this._drawTo);
    this._drawTo.set(x * w, y * h, radius, 1);

    if (this._firstUpdate) {
      this._drawFrom.copy(this._drawTo);
      this._firstUpdate = false;
    }

    const accelDissipation = config.accelDissipation ?? 0.8;
    const dx = this._drawTo.x - this._drawFrom.x;
    const dy = this._drawTo.y - this._drawFrom.y;

    this._vel.multiplyScalar(accelDissipation);
    this._vel.x += dx * dt * 0.8;
    this._vel.y += dy * dt * 0.8;

    if (config.pushStrength != null)
      this._material.uniforms.u_pushStrength.value = config.pushStrength;
    if (config.dissipations)
      this._material.uniforms.u_dissipations.value.copy(config.dissipations);
    if (config.curlScale != null)
      this._material.uniforms.u_curlScale.value = config.curlScale;
    if (config.curlStrength != null)
      this._material.uniforms.u_curlStrength.value = config.curlStrength;

    this._paint.swap();
    this._material.uniforms.u_prevPaintTexture.value = this._paint.read.texture;
    this._material.uniforms.u_lowPaintTexture.value = this._lowPaint!.texture;
    this._quad.material = this._material;

    const prev = this.renderer.getRenderTarget();

    this.renderer.setRenderTarget(this._paint.write);
    this.renderer.render(this._scene, this._camera);

    // Downsample
    this._copyMaterial.uniforms.u_source.value = this._paint.write.texture;
    this._quad.material = this._copyMaterial;
    this.renderer.setRenderTarget(this._lowPaint!);
    this.renderer.render(this._scene, this._camera);

    // 2-pass separable blur
    const lw = this._lowPaint!.width;
    const lh = this._lowPaint!.height;
    this._quad.material = this._blurMaterial;

    this._blurMaterial.uniforms.u_source.value = this._lowPaint!.texture;
    this._blurDir.set(1 / lw, 0);
    this.renderer.setRenderTarget(this._lowPaintBlur!);
    this.renderer.render(this._scene, this._camera);

    this._blurMaterial.uniforms.u_source.value = this._lowPaintBlur!.texture;
    this._blurDir.set(0, 1 / lh);
    this.renderer.setRenderTarget(this._lowPaint!);
    this.renderer.render(this._scene, this._camera);

    this.renderer.setRenderTarget(prev);
  }

  get texture() {
    return this._paint?.write?.texture ?? null;
  }

  dispose() {
    this._paint?.dispose();
    this._lowPaint?.dispose();
    this._lowPaintBlur?.dispose();
    this._material.dispose();
    this._copyMaterial.dispose();
    this._blurMaterial.dispose();
    this._clearMaterial.dispose();
    this._quad.geometry.dispose();
  }
}
