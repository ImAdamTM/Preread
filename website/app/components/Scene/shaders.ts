export const quadVert = /* glsl */ `
varying vec2 vUv;
void main() {
  vUv = uv;
  gl_Position = vec4(position, 1.0);
}
`;

export const fluidSimFrag = /* glsl */ `
uniform sampler2D u_prevPaintTexture;
uniform sampler2D u_lowPaintTexture;
uniform vec2 u_paintTexelSize;
uniform vec4 u_drawFrom;
uniform vec4 u_drawTo;
uniform float u_pushStrength;
uniform vec3 u_dissipations;
uniform vec2 u_vel;
uniform float u_curlScale;
uniform float u_curlStrength;

varying vec2 vUv;

vec2 sdSegment(in vec2 p, in vec2 a, in vec2 b) {
  vec2 pa = p - a, ba = b - a;
  float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
  return vec2(length(pa - ba * h), h);
}

vec2 hash(vec2 p) {
  vec3 p3 = fract(vec3(p.xyx) * vec3(0.1031, 0.1030, 0.0973));
  p3 += dot(p3, p3.yzx + 33.33);
  return fract((p3.xx + p3.yz) * p3.zy) * 2.0 - 1.0;
}

vec3 noised(in vec2 p) {
  vec2 i = floor(p);
  vec2 f = fract(p);
  vec2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
  vec2 du = 30.0 * f * f * (f * (f - 2.0) + 1.0);
  vec2 ga = hash(i + vec2(0.0, 0.0));
  vec2 gb = hash(i + vec2(1.0, 0.0));
  vec2 gc = hash(i + vec2(0.0, 1.0));
  vec2 gd = hash(i + vec2(1.0, 1.0));
  float va = dot(ga, f - vec2(0.0, 0.0));
  float vb = dot(gb, f - vec2(1.0, 0.0));
  float vc = dot(gc, f - vec2(0.0, 1.0));
  float vd = dot(gd, f - vec2(1.0, 1.0));
  return vec3(
    va + u.x * (vb - va) + u.y * (vc - va) + u.x * u.y * (va - vb - vc + vd),
    ga + u.x * (gb - ga) + u.y * (gc - ga) + u.x * u.y * (ga - gb - gc + gd)
      + du * (u.yx * (va - vb - vc + vd) + vec2(vb, vc) - va)
  );
}

void main() {
  vec2 res = sdSegment(gl_FragCoord.xy, u_drawFrom.xy, u_drawTo.xy);
  vec2 radiusWeight = mix(u_drawFrom.zw, u_drawTo.zw, res.y);
  float d = 1.0 - smoothstep(-0.01, radiusWeight.x, res.x);

  vec4 lowData = texture2D(u_lowPaintTexture, vUv);
  vec2 velInv = (0.5 - lowData.xy) * u_pushStrength;

  vec3 noise3 = noised(gl_FragCoord.xy * u_curlScale * (1.0 - lowData.xy));
  vec2 noise = noised(gl_FragCoord.xy * u_curlScale * (2.0 - lowData.xy * (0.5 + noise3.x) + noise3.yz * 0.1)).yz;
  velInv += noise * (lowData.z + lowData.w) * u_curlStrength;

  vec4 data = texture2D(u_prevPaintTexture, vUv + velInv * u_paintTexelSize);
  data.xy -= 0.5;

  vec4 delta = (u_dissipations.xxyz - 1.0) * data;

  vec2 newVel = u_vel * d;
  delta += vec4(newVel, radiusWeight.yy * d);
  delta.zw = sign(delta.zw) * max(vec2(0.004), abs(delta.zw));

  data += delta;
  data.xy += 0.5;

  gl_FragColor = clamp(data, vec4(0.0), vec4(1.0));
}
`;

export const fluidDistortFrag = /* glsl */ `
uniform sampler2D uFluidTexture;
uniform vec2 uFluidTexelSize;
uniform float uAmount;
uniform float uRGBShift;
uniform float uMultiplier;
uniform float uColorMultiplier;
uniform float uShade;

vec3 hash33(vec2 p) {
  vec3 p3 = fract(vec3(p.xyx) * vec3(0.1031, 0.1030, 0.0973));
  p3 += dot(p3, p3.yxz + 33.33);
  return fract((p3.xxy + p3.yxx) * p3.zyx);
}

void mainImage(const in vec4 inputColor, const in vec2 uv, out vec4 outputColor) {
  vec3 noise = hash33(gl_FragCoord.xy + vec2(17.0, 29.0));
  vec4 data = texture2D(uFluidTexture, uv);

  float weight = (data.z + data.w) * 0.5;
  vec2 vel = (0.5 - data.xy - 0.001) * 2.0 * weight;

  vec4 color = vec4(0.0);
  vec2 velocity = vel * uAmount / 4.0 * uFluidTexelSize * uMultiplier;
  vec2 sampleUv = uv + noise.xy * velocity;

  for (int i = 0; i < 9; i++) {
    color += texture2D(inputBuffer, sampleUv);
    sampleUv += velocity;
  }
  color /= 9.0;

  color.rgb += sin(vec3(vel.x + vel.y) * 40.0 + vec3(0.0, 2.0, 4.0) * uRGBShift)
    * smoothstep(0.4, -0.9, weight)
    * uShade
    * max(abs(vel.x), abs(vel.y))
    * uColorMultiplier;

  outputColor = color;
}
`;

export const blurFrag = /* glsl */ `
varying vec2 vUv;
uniform sampler2D u_source;
uniform vec2 u_direction;

void main() {
  vec4 sum = texture2D(u_source, vUv) * 0.2270;
  sum += texture2D(u_source, vUv - 1.3829 * u_direction) * 0.3160;
  sum += texture2D(u_source, vUv + 1.3829 * u_direction) * 0.3160;
  sum += texture2D(u_source, vUv - 3.2308 * u_direction) * 0.0702;
  sum += texture2D(u_source, vUv + 3.2308 * u_direction) * 0.0702;
  gl_FragColor = sum;
}
`;

export const clearFrag = /* glsl */ `
void main() {
  gl_FragColor = vec4(0.5, 0.5, 0.0, 0.0);
}
`;

export const copyFrag = /* glsl */ `
varying vec2 vUv;
uniform sampler2D u_source;

void main() {
  gl_FragColor = texture2D(u_source, vUv);
}
`;
