"use client";

import { useMemo, useRef } from "react";
import { useFrame, useThree } from "@react-three/fiber";
import * as THREE from "three";
import { simulationVertex, simulationFragment } from "./shaders";

export function useSimulation({ width = 128, height = 128 }) {
  const { camera: mainCamera, pointer } = useThree();

  const { scene, camera, material, renderTargets } = useMemo(() => {
    const count = width * height;
    const data = new Float32Array(count * 4);

    for (let i = 0; i < count; i++) {
      const theta = Math.random() * Math.PI * 2;
      const phi = Math.acos(2 * Math.random() - 1);
      const r = Math.cbrt(Math.random()) * 2.8;
      data[i * 4 + 0] = r * Math.sin(phi) * Math.cos(theta);
      data[i * 4 + 1] = r * Math.sin(phi) * Math.sin(theta) - 1.0;
      data[i * 4 + 2] = r * Math.cos(phi) * 0.3;
      data[i * 4 + 3] = Math.random();
    }

    const defaultPosTex = new THREE.DataTexture(data.slice(), width, height, THREE.RGBAFormat, THREE.FloatType);
    defaultPosTex.needsUpdate = true;

    const initPosTex = new THREE.DataTexture(data, width, height, THREE.RGBAFormat, THREE.FloatType);
    initPosTex.needsUpdate = true;

    const rtOpts = {
      minFilter: THREE.NearestFilter,
      magFilter: THREE.NearestFilter,
      format: THREE.RGBAFormat,
      type: THREE.FloatType,
      depthBuffer: false,
      stencilBuffer: false,
    };
    const rt0 = new THREE.WebGLRenderTarget(width, height, rtOpts);
    const rt1 = new THREE.WebGLRenderTarget(width, height, rtOpts);

    const simMaterial = new THREE.ShaderMaterial({
      vertexShader: simulationVertex,
      fragmentShader: simulationFragment,
      uniforms: {
        u_prevPositionTexture: { value: initPosTex },
        u_defaultPositionTexture: { value: defaultPosTex },
        u_time: { value: 0 },
        u_delta: { value: 0.016 },
        u_noiseScale: { value: 0.8 },
        u_noiseSpeed: { value: 0.3 },
        u_curlStrength: { value: 0.9 },
        u_returnStrength: { value: 1.2 },
        u_mousePos: { value: new THREE.Vector3(999, 999, 0) },
        u_mouseRadius: { value: 1.5 },
        u_mousePush: { value: 3.0 },
      },
      depthWrite: false,
      depthTest: false,
    });

    const simScene = new THREE.Scene();
    const simCamera = new THREE.OrthographicCamera(-1, 1, 1, -1, 0, 1);
    simScene.add(new THREE.Mesh(new THREE.PlaneGeometry(2, 2), simMaterial));

    return {
      scene: simScene,
      camera: simCamera,
      material: simMaterial,
      renderTargets: [rt0, rt1],
    };
  }, [width, height]);

  const frameRef = useRef(0);
  const mouseWorldRef = useRef(new THREE.Vector3(999, 999, 0));

  useFrame((state, delta) => {
    const { gl } = state;

    const mouseNDC = new THREE.Vector3(pointer.x, pointer.y, 0.5);
    mouseNDC.unproject(mainCamera);
    const dir = mouseNDC.sub(mainCamera.position).normalize();
    const dist = -mainCamera.position.z / dir.z;
    const mouseWorld = mainCamera.position.clone().add(dir.multiplyScalar(dist));
    mouseWorldRef.current.lerp(mouseWorld, 0.1);

    const currentFrame = frameRef.current;
    const readTarget = renderTargets[currentFrame % 2];
    const writeTarget = renderTargets[(currentFrame + 1) % 2];

    material.uniforms.u_time.value = state.clock.elapsedTime;
    material.uniforms.u_delta.value = Math.min(delta, 0.05);
    material.uniforms.u_mousePos.value.copy(mouseWorldRef.current);

    if (currentFrame > 0) {
      material.uniforms.u_prevPositionTexture.value = readTarget.texture;
    }

    const prevTarget = gl.getRenderTarget();
    gl.setRenderTarget(writeTarget);
    gl.render(scene, camera);
    gl.setRenderTarget(prevTarget);

    frameRef.current++;
  });

  return { renderTargets, frameRef, texSize: new THREE.Vector2(width, height) };
}
