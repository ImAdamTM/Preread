"use client";

import { useRef, useMemo, useEffect, useState } from "react";
import { Canvas, useFrame, useThree } from "@react-three/fiber";
import * as THREE from "three";
import { FlipSim, clamp, mix } from "./FlipSim";

/* ── Particle geometry: simple quad with UVs ── */
function createParticleGeo() {
  return new THREE.PlaneGeometry(0.8, 0.8);
}

/* ── Shaders ── */
const vertexShader = /* glsl */ `
  attribute vec2 instancedPos;
  attribute vec2 instancedInfo;
  uniform vec2 u_tankOffset;
  uniform vec2 u_tankActualSize;
  uniform float u_radius;
  uniform float u_opacity;
  uniform float u_aspect;

  varying vec2 v_uv;

  void main() {
    float angle = instancedInfo.x;
    float s = sin(angle), c = cos(angle);
    mat2 rot = mat2(c, -s, s, c);
    vec2 ndc = (instancedPos - u_tankOffset) / u_tankActualSize - vec2(0.5);
    ndc.y = -ndc.y;
    ndc *= 2.0;
    float particleSize = 1.0 + min(1.0, abs(instancedInfo.y) * 0.01);
    float pScale = u_radius * particleSize * 2.0 * u_opacity;
    vec2 offset = (rot * position.xy) * pScale;
    offset.y *= u_aspect;
    gl_Position = vec4(ndc + offset, 0.0, 1.0);
    v_uv = uv;
  }
`;

const fragmentShader = /* glsl */ `
  uniform sampler2D u_logoTexture;
  varying vec2 v_uv;

  void main() {
    vec4 tex = texture2D(u_logoTexture, v_uv);
    if (tex.a < 0.1) discard;
    gl_FragColor = tex;
  }
`;

/* ── R3F scene ── */
function FlipFluidScene() {
  const meshRef = useRef<THREE.Mesh>(null!);
  const simRef = useRef({
    initialized: false,
    tankW: 0,
    tankH: 0,
    w: 0,
    h: 0,
    gravity: 8,
  });
  const mouseRef = useRef({ x: 0, y: 0, prevX: 0, prevY: 0, isDown: false, onScreen: false });
  const flipSimRef = useRef<FlipSim | null>(null);
  const posBufferRef = useRef<THREE.InstancedInterleavedBuffer | null>(null);
  const infoBufferRef = useRef<THREE.InstancedInterleavedBuffer | null>(null);
  const { size, gl } = useThree();

  const logoGeo = useMemo(() => createParticleGeo(), []);

  const logoTexture = useMemo(() => {
    const tex = new THREE.TextureLoader().load("/icon-gradient.png");
    tex.minFilter = THREE.LinearFilter;
    tex.magFilter = THREE.LinearFilter;
    return tex;
  }, []);

  const uniforms = useMemo(
    () => ({
      u_tankOffset: { value: new THREE.Vector2() },
      u_tankActualSize: { value: new THREE.Vector2() },
      u_radius: { value: 0 },
      u_opacity: { value: 1 },
      u_aspect: { value: 1 },
      u_logoTexture: { value: logoTexture },
    }),
    [logoTexture],
  );

  const shaderMat = useMemo(
    () =>
      new THREE.ShaderMaterial({
        vertexShader,
        fragmentShader,
        uniforms,
        depthWrite: false,
        depthTest: false,
        transparent: true,
        side: THREE.DoubleSide,
      }),
    [uniforms],
  );

  // Track mouse relative to the canvas element
  useEffect(() => {
    const canvas = gl.domElement;
    const onMove = (e: MouseEvent) => {
      const rect = canvas.getBoundingClientRect();
      mouseRef.current.prevX = mouseRef.current.x;
      mouseRef.current.prevY = mouseRef.current.y;
      mouseRef.current.x = e.clientX - rect.left;
      mouseRef.current.y = e.clientY - rect.top;
      mouseRef.current.onScreen = true;
    };
    const onLeave = () => {
      mouseRef.current.onScreen = false;
    };
    const onDown = () => {
      mouseRef.current.isDown = true;
    };
    const onUp = () => {
      mouseRef.current.isDown = false;
    };
    const onTouch = (e: TouchEvent) => {
      if (e.touches.length > 0) {
        const rect = canvas.getBoundingClientRect();
        mouseRef.current.prevX = mouseRef.current.x;
        mouseRef.current.prevY = mouseRef.current.y;
        mouseRef.current.x = e.touches[0].clientX - rect.left;
        mouseRef.current.y = e.touches[0].clientY - rect.top;
        mouseRef.current.onScreen = true;
      }
    };
    const onTouchStart = (e: TouchEvent) => {
      onDown();
      onTouch(e);
    };
    const onTouchEnd = () => {
      onUp();
      mouseRef.current.onScreen = false;
    };
    window.addEventListener("mousemove", onMove);
    document.addEventListener("mouseleave", onLeave);
    window.addEventListener("mousedown", onDown);
    window.addEventListener("mouseup", onUp);
    window.addEventListener("touchmove", onTouch);
    window.addEventListener("touchstart", onTouchStart);
    window.addEventListener("touchend", onTouchEnd);
    return () => {
      window.removeEventListener("mousemove", onMove);
      document.removeEventListener("mouseleave", onLeave);
      window.removeEventListener("mousedown", onDown);
      window.removeEventListener("mouseup", onUp);
      window.removeEventListener("touchmove", onTouch);
      window.removeEventListener("touchstart", onTouchStart);
      window.removeEventListener("touchend", onTouchEnd);
    };
  }, [gl]);

  // Init/reinit sim on size change
  useEffect(() => {
    const w = size.width, h = size.height;
    if (w === 0 || h === 0) return;

    const aspect = h / w;
    const tankW = 2, tankH = 2 * aspect;
    const gridRes = Math.ceil(mix(20, 90, clamp((w - 320) / (2560 - 320), 0, 1)));
    const spacing = tankW / gridRes;
    const particleRadius = 0.2 * spacing;
    const pcX = Math.ceil(mix(20, 80, clamp((w - 320) / (2560 - 320), 0, 1)));
    const pcY = Math.ceil(pcX * aspect);
    const total = pcX * pcY;

    const sim = new FlipSim();
    sim.init(1, tankW, tankH, spacing, particleRadius, total);
    flipSimRef.current = sim;

    uniforms.u_tankOffset.value.set(sim.h, sim.h);
    uniforms.u_tankActualSize.value.set(sim.tankInnerWidth, sim.tankInnerHeight);
    uniforms.u_radius.value = particleRadius * 3;
    uniforms.u_aspect.value = w / h;

    const mesh = meshRef.current;
    if (!mesh) return;

    const geo = new THREE.InstancedBufferGeometry();
    geo.index = logoGeo.index;
    geo.setAttribute("position", logoGeo.attributes.position);
    if (logoGeo.attributes.uv) geo.setAttribute("uv", logoGeo.attributes.uv);

    const posBuffer = new THREE.InstancedInterleavedBuffer(sim.particlePosOut, 2, 1);
    posBuffer.setUsage(THREE.DynamicDrawUsage);
    geo.setAttribute("instancedPos", new THREE.InterleavedBufferAttribute(posBuffer, 2, 0));
    posBufferRef.current = posBuffer;

    const infoBuffer = new THREE.InstancedInterleavedBuffer(sim.particleInfo, 2, 1);
    infoBuffer.setUsage(THREE.DynamicDrawUsage);
    geo.setAttribute("instancedInfo", new THREE.InterleavedBufferAttribute(infoBuffer, 2, 0));
    infoBufferRef.current = infoBuffer;

    (geo as any)._maxInstanceCount = total;

    mesh.geometry.dispose();
    mesh.geometry = geo;
    mesh.material = shaderMat;

    simRef.current = {
      initialized: true, tankW, tankH, w, h,
      gravity: Math.abs(Math.ceil(mix(-15, -3, clamp((w - 320) / (2560 - 320), 0, 1)))),
    };
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [size]);

  useFrame((_, delta) => {
    const s = simRef.current;
    const sim = flipSimRef.current;
    if (!s.initialized || !sim) return;

    const dt = Math.max(1 / 120, Math.min(delta, 1 / 30));
    const { w, h } = s;
    const mouse = mouseRef.current;

    // Move collider offscreen when cursor has left
    let tmx: number, tmy: number, vx: number, vy: number;
    if (!mouse.onScreen) {
      tmx = -1e4;
      tmy = -1e4;
      vx = 0;
      vy = 0;
    } else {
      const mx = clamp(mouse.x, 0, w - 1);
      const my = clamp(mouse.y, 0, h - 1);
      tmx = (mx / w) * sim.tankInnerWidth + sim.h;
      tmy = (my / h) * sim.tankInnerHeight + sim.h;
      const pmx = clamp(mouse.prevX, 0, w - 1);
      const pmy = clamp(mouse.prevY, 0, h - 1);
      vx = (tmx - ((pmx / w) * sim.tankInnerWidth + sim.h)) / dt;
      vy = (tmy - ((pmy / h) * sim.tankInnerHeight + sim.h)) / dt;
    }
    const cr =
      (150 / w) *
      (mouse.isDown ? 0.35 : clamp(Math.sqrt(vx * vx + vy * vy) / 2, 0.2, 1));

    sim.isFlushing = false;
    if (!mouse.isDown) {
      sim.emitterPosA.set(sim.tankInnerWidth * 0.3 + sim.h, s.tankH * 0.5);
      sim.emitterPosB.set(sim.tankInnerWidth * 0.7 + sim.h, s.tankH * 0.5);
    } else {
      sim.isFlushing = true;
      sim.emitterPosA.set(tmx, tmy);
      sim.emitterPosB.set(tmx, tmy);
    }

    sim.simulate(
      dt,
      s.gravity * 0.3,
      0,
      20,
      1,
      0.1,
      true,
      true,
      tmx,
      tmy,
      cr,
      vx,
      vy,
    );

    // Flag buffers for GPU upload
    if (posBufferRef.current) posBufferRef.current.needsUpdate = true;
    if (infoBufferRef.current) infoBufferRef.current.needsUpdate = true;
  });

  return (
    <mesh ref={meshRef} frustumCulled={false}>
      <bufferGeometry />
      <meshBasicMaterial />
    </mesh>
  );
}

/* ── Exported wrapper ── */
export function FlipFluidCanvas({ className = "" }: { className?: string }) {
  const containerRef = useRef<HTMLDivElement>(null);
  const [visible, setVisible] = useState(false);

  useEffect(() => {
    const el = containerRef.current;
    if (!el) return;
    const observer = new IntersectionObserver(
      ([entry]) => setVisible(entry.isIntersecting),
      { threshold: 0, rootMargin: "100px" }
    );
    observer.observe(el);
    return () => observer.disconnect();
  }, []);

  return (
    <div ref={containerRef} className={className}>
      <Canvas
        orthographic
        camera={{ zoom: 1, position: [0, 0, 1], near: 0.1, far: 10 }}
        gl={{ antialias: true, alpha: true }}
        dpr={[1, 2]}
        frameloop={visible ? "always" : "never"}
        resize={{ scroll: false, debounce: { scroll: 0, resize: 100 } }}
        style={{ width: "100%", height: "100%" }}
      >
        <FlipFluidScene />
      </Canvas>
    </div>
  );
}
