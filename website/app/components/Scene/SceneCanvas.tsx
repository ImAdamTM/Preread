"use client";

import { Canvas, useFrame, useThree } from "@react-three/fiber";
import { EffectComposer } from "@react-three/postprocessing";
import { useRef } from "react";
import {
  DoubleSide,
  LinearSRGBColorSpace,
  ShaderMaterial,
  Vector2,
} from "three";
import FluidDistort from "./FluidDistortEffect";

const bgVertexShader = /* glsl */ `
  varying vec2 vUv;
  void main() {
    vUv = uv;
    gl_Position = vec4(position, 1.0);
  }
`;

/* Preread brand: black base with subtle indigo (#6B6BF0) and purple (#A855F7) ambient glows */
const bgFragmentShader = /* glsl */ `
  precision highp float;
  varying vec2 vUv;
  uniform float uTime;
  uniform vec2 uResolution;

  void main() {
    gl_FragColor = vec4(0.0, 0.0, 0.0, 1.0);
  }
`;

function BackgroundPlane() {
  const matRef = useRef<ShaderMaterial>(null);
  const size = useThree((state) => state.size);

  useFrame((_, dt) => {
    if (matRef.current) {
      matRef.current.uniforms.uTime.value += dt;
      matRef.current.uniforms.uResolution.value.set(size.width, size.height);
    }
  });

  return (
    <mesh>
      <planeGeometry args={[2, 2]} />
      <shaderMaterial
        ref={matRef}
        vertexShader={bgVertexShader}
        fragmentShader={bgFragmentShader}
        uniforms={{
          uTime: { value: 0 },
          uResolution: { value: new Vector2(1, 1) },
        }}
        side={DoubleSide}
        depthTest={false}
        depthWrite={false}
      />
    </mesh>
  );
}

export default function SceneCanvas() {
  return (
    <div className="fixed inset-0 z-0 pointer-events-none">
      <Canvas
        gl={{
          antialias: false,
          alpha: false,
          powerPreference: "high-performance",
        }}
        camera={{ fov: 25, position: [0, 0, 5], near: 0.1, far: 100 }}
        dpr={[1, 2]}
        style={{ width: "100%", height: "100%", pointerEvents: "auto" }}
        flat
        onCreated={({ gl }) => {
          gl.outputColorSpace = LinearSRGBColorSpace;
        }}
      >
        <BackgroundPlane />
        <EffectComposer multisampling={0} enableNormalPass={false}>
          <FluidDistort
            amount={3}
            multiplier={5}
            pushStrength={25}
            curlScale={0.02}
            curlStrength={1}
            rgbShift={0.1}
            colorMultiplier={10}
            shade={2.25}
            velocityDissipation={0.975}
            weight1Dissipation={0.95}
            weight2Dissipation={0.8}
            radiusDistanceRange={5}
            accelDissipation={0.8}
          />
        </EffectComposer>
      </Canvas>
    </div>
  );
}
