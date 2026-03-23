import * as THREE from "three";

const FLUID_CELL = 0,
  AIR_CELL = 1,
  SOLID_CELL = 2;
const EMIT_RATE = 2000;

function clamp(v: number, min: number, max: number) {
  return v < min ? min : v > max ? max : v;
}
function mix(a: number, b: number, t: number) {
  return a + (b - a) * t;
}
function normalizeAngle(a: number) {
  while (a > Math.PI) a -= Math.PI * 2;
  while (a < -Math.PI) a += Math.PI * 2;
  return a;
}

export { clamp, mix };

export class FlipSim {
  isFlushing = false;
  hasInitialized = false;
  emitterPosA = new THREE.Vector2(1, 1);
  emitterPosB = new THREE.Vector2(1, 1);
  numParticles = 0;
  maxParticles = 0;
  density = 0;
  fNumX = 0;
  fNumY = 0;
  h = 0;
  fInvSpacing = 0;
  tankInnerWidth = 0;
  tankInnerHeight = 0;
  u!: Float32Array;
  v!: Float32Array;
  du!: Float32Array;
  dv!: Float32Array;
  prevU!: Float32Array;
  prevV!: Float32Array;
  p!: Int8Array;
  s!: Int8Array;
  cellType!: Int8Array;
  particleDensity!: Float32Array;
  fNumCells = 0;
  particleRadius = 0;
  pInvSpacing = 0;
  pNumX = 0;
  pNumY = 0;
  particleRestDensity = 0;
  numCellParticles!: Uint32Array;
  firstCellParticle!: Uint32Array;
  pNumCells = 0;
  particlePosOut!: Float32Array;
  particlePos!: Float32Array;
  particleInfo!: Float32Array;
  particleDir!: Float32Array;
  particlePrevPos!: Float32Array;
  particleVel!: Float32Array;
  cellParticleIds!: Uint32Array;
  particleStatuses!: Uint8Array;

  init(
    density: number,
    tankW: number,
    tankH: number,
    spacing: number,
    particleRadius: number,
    maxParticles: number,
  ) {
    this.density = density;
    this.fNumX = Math.ceil(tankW / spacing) + 1;
    this.fNumY = Math.ceil(tankH / spacing) + 1;
    this.h = Math.max(tankW / this.fNumX, tankH / this.fNumY);
    this.fInvSpacing = 1 / this.h;
    const nc = this.fNumX * this.fNumY;
    this.tankInnerWidth = (this.fNumX - 2) * this.h;
    this.tankInnerHeight = (this.fNumY - 2) * this.h;
    this.u = new Float32Array(nc);
    this.v = new Float32Array(nc);
    this.du = new Float32Array(nc);
    this.dv = new Float32Array(nc);
    this.prevU = new Float32Array(nc);
    this.prevV = new Float32Array(nc);
    this.p = new Int8Array(nc);
    this.s = new Int8Array(nc);
    this.cellType = new Int8Array(nc);
    this.particleDensity = new Float32Array(nc);
    this.fNumCells = nc;
    this.particleRadius = particleRadius;
    this.pInvSpacing = 1 / (2.2 * particleRadius);
    this.pNumX = Math.floor(tankW * this.pInvSpacing) + 1;
    this.pNumY = Math.floor(tankH * this.pInvSpacing) + 1;
    this.particleRestDensity = 0;
    const pc = this.pNumX * this.pNumY;
    this.numCellParticles = new Uint32Array(pc);
    this.firstCellParticle = new Uint32Array(pc + 1);
    this.pNumCells = pc;
    this.maxParticles = maxParticles;
    this.particlePosOut = new Float32Array(2 * maxParticles);
    this.particlePos = new Float32Array(2 * maxParticles);
    this.particleInfo = new Float32Array(2 * maxParticles);
    this.particleDir = new Float32Array(2 * maxParticles);
    this.particlePrevPos = new Float32Array(2 * maxParticles);
    this.particleVel = new Float32Array(2 * maxParticles);
    this.cellParticleIds = new Uint32Array(maxParticles);
    this.particleStatuses = new Uint8Array(maxParticles);
    for (let f = 0; f < maxParticles; f++) {
      this.particlePos[f * 2] = -1e4;
      this.particlePosOut[f * 2] = -1e4;
      this.particlePrevPos[f * 2] = -1e4;
    }
    this.numParticles = maxParticles;
    const gY = this.fNumY;
    for (let i = 0; i < this.fNumX; i++)
      for (let j = 0; j < this.fNumY; j++)
        this.s[i * gY + j] =
          i > 0 && i < this.fNumX - 1 && j > 0 && j < this.fNumY - 1 ? 1 : 0;
    this.hasInitialized = true;
  }

  integrateParticles(dt: number, gravity: number) {
    for (let i = 0; i < this.numParticles; i++) {
      if (!this.particleStatuses[i]) continue;
      this.particleVel[2 * i + 1] += gravity * dt;
      this.particlePos[2 * i] += this.particleVel[2 * i] * dt;
      this.particlePos[2 * i + 1] += this.particleVel[2 * i + 1] * dt;
    }
  }

  pushParticlesApart(iters: number) {
    this.numCellParticles.fill(0);
    for (let t = 0; t < this.numParticles; t++) {
      if (!this.particleStatuses[t]) continue;
      const xi = clamp(
        Math.floor(this.particlePos[2 * t] * this.pInvSpacing),
        0,
        this.pNumX - 1,
      );
      const yi = clamp(
        Math.floor(this.particlePos[2 * t + 1] * this.pInvSpacing),
        0,
        this.pNumY - 1,
      );
      this.numCellParticles[xi * this.pNumY + yi]++;
    }
    let prefix = 0;
    for (let t = 0; t < this.pNumCells; t++) {
      prefix += this.numCellParticles[t];
      this.firstCellParticle[t] = prefix;
    }
    this.firstCellParticle[this.pNumCells] = prefix;
    for (let t = 0; t < this.numParticles; t++) {
      if (!this.particleStatuses[t]) continue;
      const xi = clamp(
        Math.floor(this.particlePos[2 * t] * this.pInvSpacing),
        0,
        this.pNumX - 1,
      );
      const yi = clamp(
        Math.floor(this.particlePos[2 * t + 1] * this.pInvSpacing),
        0,
        this.pNumY - 1,
      );
      const ci = xi * this.pNumY + yi;
      this.firstCellParticle[ci]--;
      this.cellParticleIds[this.firstCellParticle[ci]] = t;
    }
    const md = 3 * this.particleRadius,
      md2 = md * md;
    for (let iter = 0; iter < iters; iter++)
      for (let t = 0; t < this.numParticles; t++) {
        if (!this.particleStatuses[t]) continue;
        const px = this.particlePos[2 * t],
          py = this.particlePos[2 * t + 1];
        const gx = Math.floor(px * this.pInvSpacing),
          gy = Math.floor(py * this.pInvSpacing);
        for (
          let xi = Math.max(gx - 1, 0);
          xi <= Math.min(gx + 1, this.pNumX - 1);
          xi++
        )
          for (
            let yi = Math.max(gy - 1, 0);
            yi <= Math.min(gy + 1, this.pNumY - 1);
            yi++
          ) {
            const ci = xi * this.pNumY + yi;
            for (
              let k = this.firstCellParticle[ci];
              k < this.firstCellParticle[ci + 1];
              k++
            ) {
              const j = this.cellParticleIds[k];
              if (j === t || !this.particleStatuses[j]) continue;
              const dx = this.particlePos[2 * j] - px,
                dy = this.particlePos[2 * j + 1] - py;
              const d2 = dx * dx + dy * dy;
              if (d2 > md2 || d2 === 0) continue;
              const d = Math.sqrt(d2),
                s = (0.5 * (md - d)) / d;
              this.particlePos[2 * t] -= dx * s;
              this.particlePos[2 * t + 1] -= dy * s;
              this.particlePos[2 * j] += dx * s;
              this.particlePos[2 * j + 1] += dy * s;
            }
          }
      }
  }

  handleParticleCollisions(
    dt: number,
    cx: number,
    cy: number,
    cRadius: number,
    cvx: number,
    cvy: number,
  ) {
    const cs = 1 / this.fInvSpacing,
      pr = this.particleRadius;
    const cfr = cRadius + pr,
      cfr2 = cfr * cfr;
    const wL = cs + pr,
      wR = (this.fNumX - 1) * cs - pr,
      wB = cs + pr,
      wT = (this.fNumY - 1) * cs - pr;
    const _v0 = new THREE.Vector2(),
      _v1 = new THREE.Vector2(),
      _v2 = new THREE.Vector2();
    for (let i = 0; i < this.numParticles; i++) {
      if (!this.particleStatuses[i]) continue;
      let px = this.particlePos[2 * i],
        py = this.particlePos[2 * i + 1];
      const dx = px - cx,
        dy = py - cy,
        d2 = dx * dx + dy * dy;
      if (d2 < cfr2) {
        const d = Math.sqrt(d2),
          push = (cfr - d) / d;
        px += dx * push;
        py += dy * push;
        this.particleVel[2 * i] = cvx * 2;
        this.particleVel[2 * i + 1] = cvy * 2;
      }
      if (px < wL) {
        px = wL;
        this.particleVel[2 * i] = 0;
      }
      if (px > wR) {
        px = wR;
        this.particleVel[2 * i] = 0;
      }
      if (py < wB) {
        if (this.isFlushing) {
          px = -1e4;
          py = 0;
          this.particleStatuses[i] = 0;
        } else {
          py = wB;
          this.particleVel[2 * i + 1] = 0;
        }
      }
      if (py > wT) {
        py = wT;
        this.particleVel[2 * i + 1] = 0;
      }
      this.particlePos[2 * i] = px;
      this.particlePos[2 * i + 1] = py;
    }

    for (let i = 0; i < this.numParticles; i++) {
      _v0.set(this.particleVel[2 * i], this.particleVel[2 * i + 1]);
      const spd = _v0.length();
      if (spd > 1e-5) {
        _v2.set(this.particleDir[2 * i], this.particleDir[2 * i + 1]);
        _v1.set(this.particleInfo[2 * i], this.particleInfo[2 * i + 1]);
        _v1.y = mix(_v1.y, 0, 1 - Math.exp(-4 * dt));
        _v0.multiplyScalar(1 / spd);
        _v1.y +=
          spd *
          normalizeAngle(Math.atan2(_v0.y, _v0.x) - Math.atan2(_v2.y, _v2.x));
        _v1.x += _v1.y * dt;
        this.particleInfo[2 * i] = _v1.x;
        this.particleInfo[2 * i + 1] = _v1.y;
        this.particleDir[2 * i] = _v0.x;
        this.particleDir[2 * i + 1] = _v0.y;
      }
      this.particlePrevPos[2 * i] = this.particlePos[2 * i];
      this.particlePrevPos[2 * i + 1] = this.particlePos[2 * i + 1];
    }
  }

  updateParticleDensity() {
    const nY = this.fNumY,
      h = this.h,
      inv = this.fInvSpacing,
      half = 0.5 * h,
      d = this.particleDensity;
    d.fill(0);
    for (let i = 0; i < this.numParticles; i++) {
      if (!this.particleStatuses[i]) continue;
      const x = clamp(this.particlePos[2 * i], h, (this.fNumX - 1) * h);
      const y = clamp(this.particlePos[2 * i + 1], h, (this.fNumY - 1) * h);
      const x0 = Math.floor((x - half) * inv),
        tx = (x - half - x0 * h) * inv,
        x1 = Math.min(x0 + 1, this.fNumX - 2);
      const y0 = Math.floor((y - half) * inv),
        ty = (y - half - y0 * h) * inv,
        y1 = Math.min(y0 + 1, this.fNumY - 2);
      const sx = 1 - tx,
        sy = 1 - ty;
      if (x0 < this.fNumX && y0 < this.fNumY) d[x0 * nY + y0] += sx * sy;
      if (x1 < this.fNumX && y0 < this.fNumY) d[x1 * nY + y0] += tx * sy;
      if (x1 < this.fNumX && y1 < this.fNumY) d[x1 * nY + y1] += tx * ty;
      if (x0 < this.fNumX && y1 < this.fNumY) d[x0 * nY + y1] += sx * ty;
    }
    if (this.particleRestDensity === 0) {
      let sum = 0,
        cnt = 0;
      for (let i = 0; i < this.fNumCells; i++)
        if (this.cellType[i] === FLUID_CELL) {
          sum += d[i];
          cnt++;
        }
      if (cnt > 0) this.particleRestDensity = sum / cnt;
    }
  }

  transferVelocities(toGrid: boolean, flipRatio?: number) {
    const nY = this.fNumY,
      h = this.h,
      inv = this.fInvSpacing,
      half = 0.5 * h;
    if (toGrid) {
      this.prevU.set(this.u);
      this.prevV.set(this.v);
      this.du.fill(0);
      this.dv.fill(0);
      this.u.fill(0);
      this.v.fill(0);
      for (let c = 0; c < this.fNumCells; c++)
        this.cellType[c] = this.s[c] === 0 ? SOLID_CELL : AIR_CELL;
      for (let c = 0; c < this.numParticles; c++) {
        if (!this.particleStatuses[c]) continue;
        const xi = clamp(
          Math.floor(this.particlePos[2 * c] * inv),
          0,
          this.fNumX - 1,
        );
        const yi = clamp(
          Math.floor(this.particlePos[2 * c + 1] * inv),
          0,
          this.fNumY - 1,
        );
        if (this.cellType[xi * nY + yi] === AIR_CELL)
          this.cellType[xi * nY + yi] = FLUID_CELL;
      }
    }
    for (let comp = 0; comp < 2; comp++) {
      const offX = comp === 0 ? 0 : half,
        offY = comp === 0 ? half : 0;
      const f = comp === 0 ? this.u : this.v,
        fP = comp === 0 ? this.prevU : this.prevV;
      const w = comp === 0 ? this.du : this.dv;
      for (let c = 0; c < this.numParticles; c++) {
        if (!this.particleStatuses[c]) continue;
        const x = clamp(this.particlePos[2 * c], h, (this.fNumX - 1) * h);
        const y = clamp(this.particlePos[2 * c + 1], h, (this.fNumY - 1) * h);
        const x0 = Math.min(Math.floor((x - offX) * inv), this.fNumX - 2),
          tx = (x - offX - x0 * h) * inv;
        const x1 = Math.min(x0 + 1, this.fNumX - 2);
        const y0 = Math.min(Math.floor((y - offY) * inv), this.fNumY - 2),
          ty = (y - offY - y0 * h) * inv;
        const y1 = Math.min(y0 + 1, this.fNumY - 2);
        const sx = 1 - tx,
          sy = 1 - ty;
        const w00 = sx * sy,
          w10 = tx * sy,
          w11 = tx * ty,
          w01 = sx * ty;
        const i00 = x0 * nY + y0,
          i10 = x1 * nY + y0,
          i11 = x1 * nY + y1,
          i01 = x0 * nY + y1;
        if (toGrid) {
          const vel = this.particleVel[2 * c + comp];
          f[i00] += vel * w00;
          w[i00] += w00;
          f[i10] += vel * w10;
          w[i10] += w10;
          f[i11] += vel * w11;
          w[i11] += w11;
          f[i01] += vel * w01;
          w[i01] += w01;
        } else {
          const stride = comp === 0 ? nY : 1;
          const v00 =
            this.cellType[i00] !== AIR_CELL ||
            this.cellType[i00 - stride] !== AIR_CELL
              ? 1
              : 0;
          const v10 =
            this.cellType[i10] !== AIR_CELL ||
            this.cellType[i10 - stride] !== AIR_CELL
              ? 1
              : 0;
          const v11 =
            this.cellType[i11] !== AIR_CELL ||
            this.cellType[i11 - stride] !== AIR_CELL
              ? 1
              : 0;
          const v01 =
            this.cellType[i01] !== AIR_CELL ||
            this.cellType[i01 - stride] !== AIR_CELL
              ? 1
              : 0;
          const dn = v00 * w00 + v10 * w10 + v11 * w11 + v01 * w01;
          if (dn > 0) {
            const picV =
              (v00 * w00 * f[i00] +
                v10 * w10 * f[i10] +
                v11 * w11 * f[i11] +
                v01 * w01 * f[i01]) /
              dn;
            const dV =
              (v00 * w00 * (f[i00] - fP[i00]) +
                v10 * w10 * (f[i10] - fP[i10]) +
                v11 * w11 * (f[i11] - fP[i11]) +
                v01 * w01 * (f[i01] - fP[i01])) /
              dn;
            this.particleVel[2 * c + comp] =
              (1 - (flipRatio || 0)) * picV +
              (flipRatio || 0) * (this.particleVel[2 * c + comp] + dV);
          }
        }
      }
      if (toGrid) {
        for (let c = 0; c < f.length; c++) if (w[c] > 0) f[c] /= w[c];
        for (let i = 0; i < this.fNumX; i++)
          for (let j = 0; j < this.fNumY; j++) {
            const solid = this.cellType[i * nY + j] === SOLID_CELL;
            if (
              solid ||
              (i > 0 && this.cellType[(i - 1) * nY + j] === SOLID_CELL)
            )
              this.u[i * nY + j] = this.prevU[i * nY + j];
            if (
              solid ||
              (j > 0 && this.cellType[i * nY + j - 1] === SOLID_CELL)
            )
              this.v[i * nY + j] = this.prevV[i * nY + j];
          }
      }
    }
  }

  solveIncompressibility(
    iters: number,
    dt: number,
    overRelax: number,
    compensate = true,
  ) {
    this.p.fill(0);
    this.prevU.set(this.u);
    this.prevV.set(this.v);
    const n = this.fNumY;
    for (let iter = 0; iter < iters; iter++)
      for (let i = 1; i < this.fNumX - 1; i++)
        for (let j = 1; j < this.fNumY - 1; j++) {
          if (this.cellType[i * n + j] !== FLUID_CELL) continue;
          const c = i * n + j,
            l = (i - 1) * n + j,
            r = (i + 1) * n + j,
            b = i * n + j - 1,
            t = i * n + j + 1;
          const sL = this.s[l],
            sR = this.s[r],
            sB = this.s[b],
            sT = this.s[t];
          const sSum = sL + sR + sB + sT;
          if (sSum === 0) continue;
          let div = this.u[r] - this.u[c] + this.v[t] - this.v[c];
          if (this.particleRestDensity > 0 && compensate) {
            const comp = this.particleDensity[c] - this.particleRestDensity;
            if (comp > 0) div -= 0.5 * comp;
          }
          const p = (-div / sSum) * overRelax;
          this.u[c] -= sL * p;
          this.u[r] += sR * p;
          this.v[c] -= sB * p;
          this.v[t] += sT * p;
        }
  }

  simulate(
    dt: number,
    gravity: number,
    flipRatio: number,
    pressureIters: number,
    pushIters: number,
    overRelax: number,
    compensate: boolean,
    doPush: boolean,
    cx: number,
    cy: number,
    cRadius: number,
    cvx: number,
    cvy: number,
  ) {
    dt = Math.min(dt, 1 / 60);
    const emitCount = Math.ceil(EMIT_RATE * dt);
    let emitted = 0;
    for (let r = 0; r < this.numParticles && emitted < emitCount; r++) {
      if (this.particleStatuses[r] !== 0) continue;
      const t = Math.random();
      this.particlePos[2 * r] =
        this.particlePrevPos[2 * r] =
        this.particlePosOut[2 * r] =
          mix(this.emitterPosA.x, this.emitterPosB.x, t) +
          (Math.random() - 0.5) * 0.01;
      this.particlePos[2 * r + 1] =
        this.particlePrevPos[2 * r + 1] =
        this.particlePosOut[2 * r + 1] =
          mix(this.emitterPosA.y, this.emitterPosB.y, t) +
          (Math.random() - 0.5) * 0.01;
      this.particleInfo[2 * r] = Math.random() * Math.PI * 2;
      this.particleInfo[2 * r + 1] = 0;
      this.particleDir[2 * r] = 0;
      this.particleDir[2 * r + 1] = -1;
      const spd = (2 + Math.pow(Math.random(), 2) * 3) * gravity * 0.1;
      this.particleVel[r * 2] = 0;
      this.particleVel[r * 2 + 1] = spd;
      this.particleStatuses[r] = 1;
      emitted++;
    }
    this.integrateParticles(dt, gravity);
    if (doPush) this.pushParticlesApart(pushIters);
    this.handleParticleCollisions(dt, cx, cy, cRadius, cvx, cvy);
    this.transferVelocities(true);
    this.updateParticleDensity();
    this.solveIncompressibility(pressureIters, dt, overRelax, compensate);
    this.transferVelocities(false, flipRatio);
    for (let w = 0; w < this.numParticles; w++) {
      this.particlePosOut[2 * w] =
        this.particlePos[2 * w] +
        (this.particlePosOut[2 * w] - this.particlePrevPos[2 * w]) * 0.5;
      this.particlePosOut[2 * w + 1] =
        this.particlePos[2 * w + 1] +
        (this.particlePosOut[2 * w + 1] - this.particlePrevPos[2 * w + 1]) *
          0.5;
    }
  }
}
