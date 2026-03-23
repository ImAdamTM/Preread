export const simulationVertex = /* glsl */ `
precision highp float;
varying vec2 v_uv;
void main() {
  v_uv = uv;
  gl_Position = vec4(position, 1.0);
}
`;

export const simulationFragment = /* glsl */ `
precision highp float;

uniform sampler2D u_prevPositionTexture;
uniform sampler2D u_defaultPositionTexture;
uniform float u_time;
uniform float u_delta;
uniform float u_noiseScale;
uniform float u_noiseSpeed;
uniform float u_curlStrength;
uniform float u_returnStrength;
uniform vec3 u_mousePos;
uniform float u_mouseRadius;
uniform float u_mousePush;

varying vec2 v_uv;

vec4 mod289(vec4 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
float mod289(float x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
vec4 permute(vec4 x) { return mod289(((x * 34.0) + 10.0) * x); }
float permute(float x) { return mod289(((x * 34.0) + 10.0) * x); }
vec4 taylorInvSqrt(vec4 r) { return 1.79284291400159 - 0.85373472095314 * r; }
float taylorInvSqrt(float r) { return 1.79284291400159 - 0.85373472095314 * r; }

vec4 grad4(float j, vec4 ip) {
  const vec4 ones = vec4(1.0, 1.0, 1.0, -1.0);
  vec4 p, s;
  p.xyz = floor(fract(vec3(j) * ip.xyz) * 7.0) * ip.z - 1.0;
  p.w = 1.5 - dot(abs(p.xyz), ones.xyz);
  s = vec4(lessThan(p, vec4(0.0)));
  p.xyz = p.xyz + (s.xyz * 2.0 - 1.0) * s.www;
  return p;
}

#define F4 0.309016994374947451

float snoise(vec4 v) {
  const vec4 C = vec4(0.138196601125011, 0.276393202250021, 0.414589803375032, -0.447213595499958);
  vec4 i = floor(v + dot(v, vec4(F4)));
  vec4 x0 = v - i + dot(i, C.xxxx);
  vec4 i0;
  vec3 isX = step(x0.yzw, x0.xxx);
  vec3 isYZ = step(x0.zww, x0.yyz);
  i0.x = isX.x + isX.y + isX.z;
  i0.yzw = 1.0 - isX;
  i0.y += isYZ.x + isYZ.y;
  i0.zw += 1.0 - isYZ.xy;
  i0.z += isYZ.z;
  i0.w += 1.0 - isYZ.z;
  vec4 i3 = clamp(i0, 0.0, 1.0);
  vec4 i2 = clamp(i0 - 1.0, 0.0, 1.0);
  vec4 i1 = clamp(i0 - 2.0, 0.0, 1.0);
  vec4 x1 = x0 - i1 + C.xxxx;
  vec4 x2 = x0 - i2 + C.yyyy;
  vec4 x3 = x0 - i3 + C.zzzz;
  vec4 x4 = x0 + C.wwww;
  i = mod289(i);
  float j0 = permute(permute(permute(permute(i.w) + i.z) + i.y) + i.x);
  vec4 j1 = permute(permute(permute(permute(
    i.w + vec4(i1.w, i2.w, i3.w, 1.0))
    + i.z + vec4(i1.z, i2.z, i3.z, 1.0))
    + i.y + vec4(i1.y, i2.y, i3.y, 1.0))
    + i.x + vec4(i1.x, i2.x, i3.x, 1.0));
  vec4 ip = vec4(1.0/294.0, 1.0/49.0, 1.0/7.0, 0.0);
  vec4 p0 = grad4(j0, ip);
  vec4 p1 = grad4(j1.x, ip);
  vec4 p2 = grad4(j1.y, ip);
  vec4 p3 = grad4(j1.z, ip);
  vec4 p4 = grad4(j1.w, ip);
  vec4 norm = taylorInvSqrt(vec4(dot(p0,p0), dot(p1,p1), dot(p2,p2), dot(p3,p3)));
  p0 *= norm.x; p1 *= norm.y; p2 *= norm.z; p3 *= norm.w;
  p4 *= taylorInvSqrt(dot(p4,p4));
  vec3 m0 = max(0.6 - vec3(dot(x0,x0), dot(x1,x1), dot(x2,x2)), 0.0);
  vec2 m1 = max(0.6 - vec2(dot(x3,x3), dot(x4,x4)), 0.0);
  m0 = m0 * m0; m1 = m1 * m1;
  return 49.0 * (dot(m0*m0, vec3(dot(p0,x0), dot(p1,x1), dot(p2,x2))) + dot(m1*m1, vec2(dot(p3,x3), dot(p4,x4))));
}

vec3 curlNoise(vec3 p, float t) {
  const float e = 0.1;
  float n1, n2;
  vec3 curl;
  n1 = snoise(vec4(p.x, p.y + e, p.z, t));
  n2 = snoise(vec4(p.x, p.y - e, p.z, t));
  float a = (n1 - n2) / (2.0 * e);
  n1 = snoise(vec4(p.x, p.y, p.z + e, t));
  n2 = snoise(vec4(p.x, p.y, p.z - e, t));
  float b = (n1 - n2) / (2.0 * e);
  curl.x = a - b;
  n1 = snoise(vec4(p.x + e, p.y, p.z, t));
  n2 = snoise(vec4(p.x - e, p.y, p.z, t));
  a = (n1 - n2) / (2.0 * e);
  n1 = snoise(vec4(p.x, p.y, p.z + e, t));
  n2 = snoise(vec4(p.x, p.y, p.z - e, t));
  b = (n1 - n2) / (2.0 * e);
  curl.y = a - b;
  n1 = snoise(vec4(p.x + e, p.y, p.z, t));
  n2 = snoise(vec4(p.x - e, p.y, p.z, t));
  a = (n1 - n2) / (2.0 * e);
  n1 = snoise(vec4(p.x, p.y + e, p.z, t));
  n2 = snoise(vec4(p.x, p.y - e, p.z, t));
  b = (n1 - n2) / (2.0 * e);
  curl.z = a - b;
  return curl;
}

void main() {
  vec4 posLife = texture2D(u_prevPositionTexture, v_uv);
  vec3 pos = posLife.xyz;
  float life = posLife.w;
  vec3 defaultPos = texture2D(u_defaultPositionTexture, v_uv).xyz;
  float noiseTime = u_time * u_noiseSpeed;
  vec3 curl = curlNoise(pos * u_noiseScale, noiseTime);

  vec3 toMouse = pos - u_mousePos;
  float dist = length(toMouse);
  if (dist < u_mouseRadius && dist > 0.001) {
    vec3 axis = normalize(vec3(sin(noiseTime * 0.5), cos(noiseTime * 0.5), 0.0));
    vec3 spinDir = cross(axis, normalize(toMouse));
    float spinStrength = smoothstep(u_mouseRadius, 0.0, dist) * u_mousePush;
    vec3 pushDir = normalize(toMouse);
    pos += (spinDir * spinStrength + pushDir * spinStrength * 0.5) * u_delta;
  }

  pos += curl * u_curlStrength * u_delta;
  vec3 returnForce = (defaultPos - pos) * u_returnStrength;
  pos += returnForce * u_delta;

  float boundaryRadius = 3.5;
  float distFromCenter = length(pos);
  if (distFromCenter > boundaryRadius) {
    pos = normalize(pos) * boundaryRadius;
  }

  gl_FragColor = vec4(pos, life);
}
`;

export const particleVertex = /* glsl */ `
precision highp float;

uniform sampler2D u_positionTexture;
uniform vec2 u_texSize;
uniform float u_particleScale;
uniform float u_time;

attribute vec2 a_simUv;

varying vec3 v_normal;
varying float v_depth;

vec4 hash43(vec3 p) {
  vec4 p4 = fract(vec4(p.xyzx) * vec4(0.1031, 0.1030, 0.0973, 0.1099));
  p4 += dot(p4, p4.wzxy + 33.33);
  return fract((p4.xxyz + p4.yzzw) * p4.zywx);
}

void main() {
  vec4 posLife = texture2D(u_positionTexture, a_simUv);
  vec3 particlePos = posLife.xyz;
  vec4 rands = hash43(vec3(a_simUv, 0.0));
  float sizeVariation = mix(0.4, 1.0, rands.x);
  float scale = u_particleScale * sizeVariation;
  float angle = rands.y * 6.2831 + u_time * (rands.z - 0.5) * 2.0;
  float ca = cos(angle);
  float sa = sin(angle);
  vec3 rotatedPos = position;
  rotatedPos.xy = mat2(ca, -sa, sa, ca) * rotatedPos.xy;
  vec3 finalPos = rotatedPos * scale + particlePos;
  vec4 mvPosition = modelViewMatrix * vec4(finalPos, 1.0);
  gl_Position = projectionMatrix * mvPosition;
  v_normal = normalize(normalMatrix * normal);
  v_depth = -mvPosition.z;
}
`;

export const particleFragment = /* glsl */ `
precision highp float;

varying vec3 v_normal;
varying float v_depth;

void main() {
  float light = dot(v_normal, normalize(vec3(0.5, 1.0, 0.5))) * 0.3 + 0.7;
  float fog = smoothstep(2.0, 12.0, v_depth);

  // Preread brand: indigo/purple particles on black
  vec3 bgColor = vec3(0.0, 0.0, 0.0);
  vec3 particleColor = vec3(0.506, 0.553, 0.973) * light; // #818CF8

  vec3 finalColor = mix(particleColor, bgColor, fog * 0.6);
  float alpha = mix(0.35, 0.05, fog);

  gl_FragColor = vec4(finalColor, alpha);
}
`;
