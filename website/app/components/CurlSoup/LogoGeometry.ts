import * as THREE from "three";

/**
 * Creates an extruded geometry of the Preread "P" logomark.
 * The SVG path is converted to a THREE.Shape for extrusion.
 */
export function createLogoGeometry(size = 0.5) {
  const scale = size / 352;

  // Simplified P logo as a THREE.Shape
  // The full SVG path is complex, so we use a simplified version
  // that captures the distinctive "P" with the nested counter
  const shape = new THREE.Shape();

  // Outer P shape
  shape.moveTo(0 * scale, 352 * scale);
  shape.lineTo(0 * scale, 0 * scale);
  shape.lineTo(188 * scale, 0 * scale);

  // Top-right curve of P (approximated with bezier)
  shape.bezierCurveTo(
    230 * scale, 0 * scale,
    270 * scale, 20 * scale,
    300 * scale, 60 * scale
  );
  shape.bezierCurveTo(
    325 * scale, 100 * scale,
    325 * scale, 170 * scale,
    300 * scale, 210 * scale
  );
  shape.bezierCurveTo(
    270 * scale, 255 * scale,
    230 * scale, 275 * scale,
    188 * scale, 275 * scale
  );
  shape.lineTo(78 * scale, 275 * scale);
  shape.lineTo(78 * scale, 78 * scale);
  shape.lineTo(178 * scale, 78 * scale);

  // Inner curve of P bowl
  shape.bezierCurveTo(
    210 * scale, 78 * scale,
    238 * scale, 105 * scale,
    238 * scale, 137 * scale
  );
  shape.bezierCurveTo(
    238 * scale, 169 * scale,
    210 * scale, 196 * scale,
    178 * scale, 196 * scale
  );
  shape.lineTo(152 * scale, 196 * scale);
  shape.lineTo(152 * scale, 152 * scale);
  shape.lineTo(178 * scale, 152 * scale);
  shape.bezierCurveTo(
    186 * scale, 152 * scale,
    193 * scale, 145 * scale,
    193 * scale, 137 * scale
  );
  shape.bezierCurveTo(
    193 * scale, 129 * scale,
    186 * scale, 122 * scale,
    178 * scale, 122 * scale
  );
  shape.lineTo(96 * scale, 122 * scale);
  shape.lineTo(96 * scale, 230 * scale);
  shape.lineTo(162 * scale, 230 * scale);

  // Outer bowl curve back
  shape.bezierCurveTo(
    196 * scale, 230 * scale,
    225 * scale, 210 * scale,
    240 * scale, 180 * scale
  );
  shape.bezierCurveTo(
    255 * scale, 150 * scale,
    255 * scale, 110 * scale,
    240 * scale, 80 * scale
  );
  shape.bezierCurveTo(
    225 * scale, 55 * scale,
    200 * scale, 44 * scale,
    162 * scale, 44 * scale
  );
  shape.lineTo(44 * scale, 44 * scale);
  shape.lineTo(44 * scale, 308 * scale);
  shape.lineTo(122 * scale, 308 * scale);
  shape.lineTo(122 * scale, 352 * scale);
  shape.lineTo(0 * scale, 352 * scale);

  const geo = new THREE.ExtrudeGeometry(shape, {
    depth: size * 0.15,
    bevelEnabled: false,
  });

  // Center and flip Y (SVG Y is inverted vs Three.js)
  geo.center();
  geo.rotateX(Math.PI); // flip since SVG y goes down

  return geo;
}
