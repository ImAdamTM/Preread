'use client';

import { useFrame, useThree } from '@react-three/fiber';
import { Effect } from 'postprocessing';
import { forwardRef, useEffect, useMemo, useRef } from 'react';
import { Uniform, Vector2, Vector3 } from 'three';
import FluidSim from './FluidSim';
import { fluidDistortFrag } from './shaders';

class FluidDistortImpl extends Effect {
  constructor({ fluidSim }: { fluidSim: FluidSim }) {
    super('FluidDistort', fluidDistortFrag, {
      uniforms: new Map<string, Uniform>([
        ['uFluidTexture', new Uniform(null)],
        ['uFluidTexelSize', new Uniform(fluidSim.texelSize)],
        ['uAmount', new Uniform(20)],
        ['uRGBShift', new Uniform(1)],
        ['uMultiplier', new Uniform(1.25)],
        ['uColorMultiplier', new Uniform(1)],
        ['uShade', new Uniform(1.25)]
      ])
    });
  }
}

interface FluidDistortProps {
  accelDissipation?: number;
  amount?: number;
  colorMultiplier?: number;
  curlScale?: number;
  curlStrength?: number;
  multiplier?: number;
  pushStrength?: number;
  radiusDistanceRange?: number;
  rgbShift?: number;
  shade?: number;
  velocityDissipation?: number;
  weight1Dissipation?: number;
  weight2Dissipation?: number;
}

const PRESSURE_ATTACK = 0.06;
const PRESSURE_RELEASE = 0.15;

const FluidDistort = forwardRef<Effect, FluidDistortProps>(function FluidDistort(
  {
    accelDissipation = 0.8,
    amount = 3,
    colorMultiplier = 10,
    curlScale = 0.02,
    curlStrength = 3,
    multiplier = 5,
    pushStrength = 25,
    radiusDistanceRange = 100,
    rgbShift = 0.5,
    shade = 1.25,
    velocityDissipation = 0.975,
    weight1Dissipation = 0.95,
    weight2Dissipation = 0.8
  },
  ref
) {
  const gl = useThree(state => state.gl);
  const size = useThree(state => state.size);

  const fluidSim = useMemo(() => new FluidSim(gl), [gl]);
  const effect = useMemo(() => new FluidDistortImpl({ fluidSim }), [fluidSim]);

  useEffect(
    () => () => {
      effect.dispose();
      fluidSim.dispose();
    },
    [effect, fluidSim]
  );

  useEffect(() => {
    effect.uniforms.get('uAmount')!.value = amount;
    effect.uniforms.get('uRGBShift')!.value = rgbShift;
    effect.uniforms.get('uMultiplier')!.value = multiplier;
    effect.uniforms.get('uColorMultiplier')!.value = colorMultiplier;
    effect.uniforms.get('uShade')!.value = shade;
  }, [effect, amount, rgbShift, multiplier, colorMultiplier, shade]);

  const fluidTextureUniform = useMemo(() => effect.uniforms.get('uFluidTexture')!, [effect]);
  const fluidTexelUniform = useMemo(() => effect.uniforms.get('uFluidTexelSize')!, [effect]);

  const pointerUv = useRef(new Vector2(0.5, 0.5));
  const prevUv = useRef(new Vector2(0.5, 0.5));
  const pressure = useRef(0);
  const wasActive = useRef(false);
  const dissipations = useRef(new Vector3());
  const pointerOnScreen = useRef(false);

  useEffect(() => {
    const onMove = (e: PointerEvent) => {
      pointerUv.current.set(
        e.clientX / window.innerWidth,
        1.0 - e.clientY / window.innerHeight
      );
      pointerOnScreen.current = true;
    };
    const onLeave = () => { pointerOnScreen.current = false; };

    window.addEventListener('pointermove', onMove);
    document.addEventListener('pointerleave', onLeave);
    return () => {
      window.removeEventListener('pointermove', onMove);
      document.removeEventListener('pointerleave', onLeave);
    };
  }, []);

  useFrame((_, dt) => {
    dt = Math.min(dt, 0.05);

    fluidSim.resize(size.width, size.height);

    // Always active when cursor is on screen
    const active = pointerOnScreen.current;
    const target = active ? 1 : 0;
    const rate = active ? PRESSURE_ATTACK : PRESSURE_RELEASE;
    pressure.current += (target - pressure.current) * rate;
    if (Math.abs(pressure.current - target) < 0.001) pressure.current = target;

    const isActive = pressure.current > 0.01;

    if (isActive && !wasActive.current) {
      prevUv.current.set(pointerUv.current.x, pointerUv.current.y);
    }
    wasActive.current = isActive;

    const dx = pointerUv.current.x - prevUv.current.x;
    const dy = pointerUv.current.y - prevUv.current.y;
    const pixelDist = Math.sqrt((dx * size.width) ** 2 + (dy * size.height) ** 2);

    const simH = fluidSim._paint?.read?.height ?? 1;
    const maxRadVp = Math.max(40, size.width / 20);
    const radiusVp = Math.min(maxRadVp, (pixelDist / radiusDistanceRange) * maxRadVp);
    const radius = isActive ? (radiusVp / size.height) * simH : 0;

    dissipations.current.set(velocityDissipation, weight1Dissipation, weight2Dissipation);

    fluidSim.update(pointerUv.current.x, pointerUv.current.y, radius, dt, {
      accelDissipation,
      pushStrength,
      curlScale,
      curlStrength,
      dissipations: dissipations.current
    });

    prevUv.current.set(pointerUv.current.x, pointerUv.current.y);

    fluidTextureUniform.value = fluidSim.texture;
    fluidTexelUniform.value = fluidSim.texelSize;
  });

  return <primitive ref={ref} object={effect} />;
});

export default FluidDistort;
