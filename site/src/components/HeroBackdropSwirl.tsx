import { useEffect, useRef } from 'react'

// Backdrop candidate B: a hand-rolled WebGL2 swirl (fine marbled threads of
// light, the "Prism" look from the source component) retuned to the page's
// amber. Same contract as HeroBackdrop: fills .hero-backdrop, decorative
// only, freezes under reduced motion, and the static radial gradient behind
// it is the fallback when WebGL2 is unavailable.
//
// Colour values restate the theme.css tokens because uniforms take literal
// colours, not CSS variables; the brightest thread is the accent itself.
const PARAMS = {
  color1: '#0a0a0c',
  color2: '#3b230d',
  color3: '#e8a13a',
  rotation: -50,
  proportion: 0.01,
  scale: 0.01,
  speed: 6,
  distortion: 0,
  swirl: 0.5,
  swirlIterations: 16,
  softness: 0.47,
  offset: -299,
  shapeScale: 0.45,
  // On the canvas, not the wrapper: the wrapper's entrance animation ends at
  // opacity 1 and fill-mode both holds it there, so a wrapper opacity never
  // survives the fade-in.
  dim: 0.5,
}

function hexToRgb(hex: string): [number, number, number] {
  const c = hex.slice(1)
  return [
    parseInt(c.slice(0, 2), 16) / 255,
    parseInt(c.slice(2, 4), 16) / 255,
    parseInt(c.slice(4, 6), 16) / 255,
  ]
}

const VERTEX_SHADER = `#version 300 es
in vec4 a_position;
void main() {
  gl_Position = a_position;
}`

const FRAGMENT_SHADER = `#version 300 es
precision highp float;

uniform float u_time;
uniform float u_pixelRatio;
uniform vec2 u_resolution;

uniform float u_scale;
uniform float u_rotation;
uniform vec4 u_color1;
uniform vec4 u_color2;
uniform vec4 u_color3;
uniform float u_proportion;
uniform float u_softness;
uniform float u_shapeScale;
uniform float u_distortion;
uniform float u_swirl;
uniform float u_swirlIterations;

out vec4 fragColor;

#define TWO_PI 6.28318530718
#define PI 3.14159265358979323846

vec2 rotate(vec2 uv, float th) {
  return mat2(cos(th), sin(th), -sin(th), cos(th)) * uv;
}

float random(vec2 st) {
  return fract(sin(dot(st.xy, vec2(12.9898, 78.233))) * 43758.5453123);
}

float noise(vec2 st) {
  vec2 i = floor(st);
  vec2 f = fract(st);
  float a = random(i);
  float b = random(i + vec2(1.0, 0.0));
  float c = random(i + vec2(0.0, 1.0));
  float d = random(i + vec2(1.0, 1.0));

  vec2 u = f * f * (3.0 - 2.0 * f);

  float x1 = mix(a, b, u.x);
  float x2 = mix(c, d, u.x);
  return mix(x1, x2, u.y);
}

vec4 blend_colors(vec4 c1, vec4 c2, vec4 c3, float mixer, float edgesWidth, float edge_blur) {
    vec3 color1 = c1.rgb * c1.a;
    vec3 color2 = c2.rgb * c2.a;
    vec3 color3 = c3.rgb * c3.a;

    float r1 = smoothstep(.0 + .35 * edgesWidth, .7 - .35 * edgesWidth + .5 * edge_blur, mixer);
    float r2 = smoothstep(.3 + .35 * edgesWidth, 1. - .35 * edgesWidth + edge_blur, mixer);

    vec3 blended_color_2 = mix(color1, color2, r1);
    float blended_opacity_2 = mix(c1.a, c2.a, r1);

    vec3 c = mix(blended_color_2, color3, r2);
    float o = mix(blended_opacity_2, c3.a, r2);
    return vec4(c, o);
}

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution.xy;

    float t = .5 * u_time;

    float noise_scale = .0005 + .006 * u_scale;

    uv -= .5;
    uv *= (noise_scale * u_resolution);
    uv = rotate(uv, u_rotation * .5 * PI);
    uv /= u_pixelRatio;
    uv += .5;

    float n1 = noise(uv * 1. + t);
    float n2 = noise(uv * 2. - t);
    float angle = n1 * TWO_PI;
    uv.x += 4. * u_distortion * n2 * cos(angle);
    uv.y += 4. * u_distortion * n2 * sin(angle);

    float iterations_number = ceil(clamp(u_swirlIterations, 1., 30.));
    for (float i = 1.; i <= iterations_number; i++) {
        uv.x += clamp(u_swirl, 0., 2.) / i * cos(t + i * 1.5 * uv.y);
        uv.y += clamp(u_swirl, 0., 2.) / i * cos(t + i * 1. * uv.x);
    }

    float proportion = clamp(u_proportion, 0., 1.);

    vec2 checks_shape_uv = uv * (.5 + 3.5 * u_shapeScale);
    float shape = .5 + .5 * sin(checks_shape_uv.x) * cos(checks_shape_uv.y);
    float mixer = shape + .48 * sign(proportion - .5) * pow(abs(proportion - .5), .5);

    vec4 color_mix = blend_colors(u_color1, u_color2, u_color3, mixer, 1. - clamp(u_softness, 0., 1.), .01 + .01 * u_scale);

    fragColor = vec4(color_mix.rgb, color_mix.a);
}
`

export function HeroBackdropSwirl() {
  const canvasRef = useRef<HTMLCanvasElement>(null)
  const wrapRef = useRef<HTMLDivElement>(null)

  useEffect(() => {
    type IdleWindow = Window & {
      requestIdleCallback?: (callback: () => void, options?: { timeout: number }) => number
      cancelIdleCallback?: (id: number) => void
    }

    const idleWindow = window as IdleWindow
    let disposed = false
    let teardown = () => {}

    const initialize = () => {
      if (disposed) return
      const canvas = canvasRef.current
      const wrap = wrapRef.current
      if (!canvas || !wrap) return

      const gl = canvas.getContext('webgl2', { premultipliedAlpha: true, antialias: true })
      if (!gl) return

      const compile = (type: number, source: string) => {
        const shader = gl.createShader(type)!
        gl.shaderSource(shader, source)
        gl.compileShader(shader)
        return shader
      }
      const vertexShader = compile(gl.VERTEX_SHADER, VERTEX_SHADER)
      const fragmentShader = compile(gl.FRAGMENT_SHADER, FRAGMENT_SHADER)
      const program = gl.createProgram()!
      gl.attachShader(program, vertexShader)
      gl.attachShader(program, fragmentShader)
      gl.linkProgram(program)
      gl.useProgram(program)

      const positionBuffer = gl.createBuffer()
      gl.bindBuffer(gl.ARRAY_BUFFER, positionBuffer)
      gl.bufferData(
        gl.ARRAY_BUFFER,
        new Float32Array([-1, -1, 1, -1, -1, 1, -1, 1, 1, -1, 1, 1]),
        gl.STATIC_DRAW,
      )
      const positionLocation = gl.getAttribLocation(program, 'a_position')
      gl.enableVertexAttribArray(positionLocation)
      gl.vertexAttribPointer(positionLocation, 2, gl.FLOAT, false, 0, 0)

      const u = (name: string) => gl.getUniformLocation(program, name)
      const [r1, g1, b1] = hexToRgb(PARAMS.color1)
      const [r2, g2, b2] = hexToRgb(PARAMS.color2)
      const [r3, g3, b3] = hexToRgb(PARAMS.color3)
      gl.uniform4f(u('u_color1'), r1, g1, b1, 1)
      gl.uniform4f(u('u_color2'), r2, g2, b2, 1)
      gl.uniform4f(u('u_color3'), r3, g3, b3, 1)
      gl.uniform1f(u('u_scale'), PARAMS.scale)
      gl.uniform1f(u('u_rotation'), (PARAMS.rotation * Math.PI) / 180)
      gl.uniform1f(u('u_proportion'), PARAMS.proportion)
      gl.uniform1f(u('u_softness'), PARAMS.softness)
      gl.uniform1f(u('u_shapeScale'), PARAMS.shapeScale)
      gl.uniform1f(u('u_distortion'), PARAMS.distortion)
      gl.uniform1f(u('u_swirl'), PARAMS.swirl)
      gl.uniform1f(u('u_swirlIterations'), PARAMS.swirlIterations)
      const uTime = u('u_time')
      const uResolution = u('u_resolution')
      const uPixelRatio = u('u_pixelRatio')

      // The observer hands over the wrapper's size, so no layout read is
      // forced mid-frame; only the first sizing reads the element itself.
      const resize = (width: number, height: number) => {
        // The backdrop is atmospheric, not content. Capping its internal
        // resolution keeps a Retina display from quadrupling the fragment work.
        const pixelRatio = Math.min(window.devicePixelRatio || 1, 1.5)
        canvas.width = Math.round(width * pixelRatio)
        canvas.height = Math.round(height * pixelRatio)
        gl.viewport(0, 0, canvas.width, canvas.height)
      }
      resize(wrap.clientWidth, wrap.clientHeight)
      const resizeObserver = new ResizeObserver((entries) => {
        const rect = entries[0]?.contentRect
        if (rect) resize(rect.width, rect.height)
      })
      resizeObserver.observe(wrap)

      const reduced = window.matchMedia('(prefers-reduced-motion: reduce)')
      const start = performance.now()
      let frameId = 0
      let onScreen = true

      const draw = (time: number) => {
        const elapsed = (time - start) / 1000
        const speed = (PARAMS.speed / 100) * 5
        gl.uniform1f(uTime, elapsed * speed + PARAMS.offset * 0.01)
        gl.uniform2f(uResolution, canvas.width, canvas.height)
        gl.uniform1f(uPixelRatio, Math.min(window.devicePixelRatio || 1, 1.5))
        gl.drawArrays(gl.TRIANGLES, 0, 6)
      }
      const animate = (time: number) => {
        draw(time)
        frameId = requestAnimationFrame(animate)
      }
      // Reduced motion still gets the composition, held on its first frame.
      // Ordinary motion stops whenever the backdrop is offscreen or the page
      // is hidden, so the flourish has no background CPU cost.
      const run = () => {
        cancelAnimationFrame(frameId)
        if (reduced.matches) draw(performance.now())
        else if (onScreen && !document.hidden) frameId = requestAnimationFrame(animate)
      }
      const visibilityObserver = new IntersectionObserver(([entry]) => {
        onScreen = entry.isIntersecting
        run()
      })
      visibilityObserver.observe(wrap)
      document.addEventListener('visibilitychange', run)
      reduced.addEventListener('change', run)
      run()

      teardown = () => {
        cancelAnimationFrame(frameId)
        reduced.removeEventListener('change', run)
        document.removeEventListener('visibilitychange', run)
        visibilityObserver.disconnect()
        resizeObserver.disconnect()
        gl.deleteProgram(program)
        gl.deleteShader(vertexShader)
        gl.deleteShader(fragmentShader)
        gl.deleteBuffer(positionBuffer)
      }
    }

    const idleId = idleWindow.requestIdleCallback?.(initialize, { timeout: 1500 })
    const timerId = idleId === undefined ? window.setTimeout(initialize, 500) : 0

    return () => {
      disposed = true
      if (idleId !== undefined) idleWindow.cancelIdleCallback?.(idleId)
      if (timerId) window.clearTimeout(timerId)
      teardown()
    }
  }, [])

  return (
    <div className="hero-backdrop" ref={wrapRef} aria-hidden="true">
      <canvas
        ref={canvasRef}
        style={{ display: 'block', width: '100%', height: '100%', opacity: PARAMS.dim }}
      />
    </div>
  )
}
