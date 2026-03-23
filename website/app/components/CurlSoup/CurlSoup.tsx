"use client";

import { Suspense, useMemo, useRef } from "react";
import { Canvas, useFrame } from "@react-three/fiber";
import * as THREE from "three";
import { useSimulation } from "./useSimulation";
import { createLogoGeometry } from "./LogoGeometry";
import { particleVertex, particleFragment } from "./shaders";

const SIM_WIDTH = 128;
const SIM_HEIGHT = 128;
const PARTICLE_COUNT = SIM_WIDTH * SIM_HEIGHT;

function ParticleSoup() {
  const sim = useSimulation({ width: SIM_WIDTH, height: SIM_HEIGHT });

  const logoGeo = useMemo(() => createLogoGeometry(0.5), []);

  const instanceData = useMemo(() => {
    const simUvs = new Float32Array(PARTICLE_COUNT * 2);
    for (let i = 0; i < PARTICLE_COUNT; i++) {
      simUvs[i * 2] = (i % SIM_WIDTH) / SIM_WIDTH + 0.5 / SIM_WIDTH;
      simUvs[i * 2 + 1] = Math.floor(i / SIM_WIDTH) / SIM_HEIGHT + 0.5 / SIM_HEIGHT;
    }
    return simUvs;
  }, []);

  const shaderMaterial = useMemo(() => {
    return new THREE.ShaderMaterial({
      vertexShader: particleVertex,
      fragmentShader: particleFragment,
      uniforms: {
        u_positionTexture: { value: null },
        u_texSize: { value: new THREE.Vector2(SIM_WIDTH, SIM_HEIGHT) },
        u_particleScale: { value: 0.07 },
        u_time: { value: 0 },
      },
      side: THREE.DoubleSide,
      transparent: true,
      depthWrite: false,
      depthTest: true,
    });
  }, []);

  const instancedGeo = useMemo(() => {
    const geo = new THREE.InstancedBufferGeometry();
    geo.index = logoGeo.index;
    geo.attributes.position = logoGeo.attributes.position;
    geo.attributes.normal = logoGeo.attributes.normal;
    if (logoGeo.attributes.uv) {
      geo.attributes.uv = logoGeo.attributes.uv;
    }
    geo.setAttribute("a_simUv", new THREE.InstancedBufferAttribute(instanceData, 2));
    geo.instanceCount = PARTICLE_COUNT;
    return geo;
  }, [logoGeo, instanceData]);

  useFrame((state) => {
    const currentIdx = sim.frameRef.current % 2;
    const tex = sim.renderTargets[currentIdx].texture;
    shaderMaterial.uniforms.u_positionTexture.value = tex;
    shaderMaterial.uniforms.u_time.value = state.clock.elapsedTime;
  });

  return <mesh geometry={instancedGeo} material={shaderMaterial} frustumCulled={false} />;
}

export function CurlSoup({ className = "" }: { className?: string }) {
  return (
    <div className={className}>
      <Canvas
        camera={{ position: [0, 0, 5], fov: 50 }}
        gl={{ antialias: true, alpha: true }}
        dpr={[1, 2]}
        style={{ width: "100%", height: "100%" }}
      >
        <Suspense fallback={null}>
          <ParticleSoup />
        </Suspense>
      </Canvas>
    </div>
  );
}
