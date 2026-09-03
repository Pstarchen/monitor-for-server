<script setup lang="ts">
import { onBeforeUnmount, onMounted, ref } from 'vue'

const host = ref<HTMLDivElement>()
const failed = ref(false)
let disposeScene = () => {}

onMounted(async () => {
  if (!host.value) return

  try {
    const THREE = await import('three')
    const scene = new THREE.Scene()
    scene.fog = new THREE.FogExp2(0x05080b, 0.045)

    const camera = new THREE.PerspectiveCamera(35, 1, 0.1, 80)
    camera.position.set(0.1, 0.5, 10.2)

    const renderer = new THREE.WebGLRenderer({
      antialias: true,
      alpha: true,
      powerPreference: 'high-performance',
      preserveDrawingBuffer: true,
    })
    renderer.setPixelRatio(Math.min(window.devicePixelRatio, 1.6))
    renderer.setClearColor(0x05080b, 0)
    renderer.outputColorSpace = THREE.SRGBColorSpace
    renderer.toneMapping = THREE.ACESFilmicToneMapping
    renderer.toneMappingExposure = 1.28
    renderer.shadowMap.enabled = true
    renderer.shadowMap.type = THREE.PCFSoftShadowMap
    renderer.domElement.setAttribute('aria-hidden', 'true')
    host.value.appendChild(renderer.domElement)

    const world = new THREE.Group()
    world.position.set(1.45, -0.02, 0)
    scene.add(world)

    const metal = new THREE.MeshStandardMaterial({ color: 0x84929a, metalness: 0.92, roughness: 0.27 })
    const darkMetal = new THREE.MeshStandardMaterial({ color: 0x0a1217, metalness: 0.78, roughness: 0.32 })
    const trim = new THREE.MeshStandardMaterial({ color: 0xb8cbd1, metalness: 0.96, roughness: 0.2 })
    const cyan = new THREE.MeshBasicMaterial({ color: 0x72e4ff, toneMapped: false, transparent: true })
    const green = new THREE.MeshBasicMaterial({ color: 0x77e1a6, toneMapped: false, transparent: true })
    const coldGlass = new THREE.MeshPhysicalMaterial({
      color: 0x15313b,
      metalness: 0.15,
      roughness: 0.12,
      transmission: 0.16,
      transparent: true,
      opacity: 0.56,
    })

    const createRack = (x: number, y: number, z: number, scale = 1) => {
      const rack = new THREE.Group()
      rack.position.set(x, y, z)
      rack.scale.setScalar(scale)

      const shell = new THREE.Mesh(new THREE.BoxGeometry(1.65, 3.35, 1.5), metal)
      shell.castShadow = true
      rack.add(shell)

      const side = new THREE.Mesh(new THREE.BoxGeometry(1.52, 3.12, 1.42), darkMetal)
      side.position.z = 0.04
      rack.add(side)

      const topCap = new THREE.Mesh(new THREE.BoxGeometry(1.72, 0.1, 1.58), trim)
      topCap.position.y = 1.7
      rack.add(topCap)

      const statusBar = new THREE.Mesh(new THREE.BoxGeometry(1.28, 0.04, 0.03), cyan)
      statusBar.position.set(0, 1.49, 0.835)
      rack.add(statusBar)

      for (let unit = 0; unit < 9; unit += 1) {
        const face = new THREE.Mesh(new THREE.BoxGeometry(1.48, 0.27, 0.08), darkMetal)
        face.position.set(0, -1.26 + unit * 0.315, 0.78)
        rack.add(face)

        const slot = new THREE.Mesh(new THREE.BoxGeometry(0.66, 0.035, 0.025), trim)
        slot.position.set(-0.22, face.position.y, 0.83)
        rack.add(slot)

        for (let vent = 0; vent < 3; vent += 1) {
          const ventSlot = new THREE.Mesh(new THREE.BoxGeometry(0.08, 0.06, 0.025), coldGlass)
          ventSlot.position.set(-0.57 + vent * 0.13, face.position.y, 0.835)
          rack.add(ventSlot)
        }

        const led = new THREE.Mesh(new THREE.SphereGeometry(0.035, 10, 10), unit % 4 === 0 ? green : cyan)
        led.position.set(0.55, face.position.y, 0.835)
        rack.add(led)
      }

      const edges = new THREE.LineSegments(
        new THREE.EdgesGeometry(new THREE.BoxGeometry(1.67, 3.37, 1.52)),
        new THREE.LineBasicMaterial({ color: 0x9ab0be, transparent: true, opacity: 0.45 }),
      )
      rack.add(edges)
      return rack
    }

    const backRack = createRack(0.15, 0.35, -1.45, 0.9)
    const leftRack = createRack(-1.18, -0.15, 0.05, 1.03)
    const mainRack = createRack(0.6, -0.05, 0.65, 1.12)
    world.add(backRack, leftRack, mainRack)

    const plinth = new THREE.Mesh(new THREE.BoxGeometry(5.1, 0.14, 3.5), darkMetal)
    plinth.position.set(-0.05, -1.92, -0.05)
    plinth.receiveShadow = true
    world.add(plinth)

    const panelCanvas = document.createElement('canvas')
    panelCanvas.width = 640
    panelCanvas.height = 420
    const panelContext = panelCanvas.getContext('2d')
    if (panelContext) {
      panelContext.fillStyle = 'rgba(5, 16, 21, 0.92)'
      panelContext.fillRect(0, 0, panelCanvas.width, panelCanvas.height)
      panelContext.fillStyle = 'rgba(128, 226, 240, 0.94)'
      panelContext.font = '600 26px Segoe UI, sans-serif'
      panelContext.fillText('XINGCHEN / LIVE', 38, 52)
      panelContext.fillStyle = 'rgba(133, 159, 166, 0.92)'
      panelContext.font = '500 18px Cascadia Code, monospace'
      panelContext.fillText('24 NODES', 495, 50)
      panelContext.fillText('CPU LOAD', 38, 104)
      panelContext.fillText('MEMORY', 38, 250)
      panelContext.strokeStyle = 'rgba(110, 187, 216, 0.2)'
      panelContext.lineWidth = 2
      for (let y = 120; y < panelCanvas.height; y += 58) {
        panelContext.beginPath()
        panelContext.moveTo(42, y)
        panelContext.lineTo(598, y)
        panelContext.stroke()
      }
      const drawWave = (offset: number, color: string, amplitude: number) => {
        panelContext.beginPath()
        for (let x = 42; x <= 598; x += 4) {
          const y = offset + Math.sin(x * 0.026) * amplitude + Math.sin(x * 0.071) * amplitude * 0.38
          if (x === 42) panelContext.moveTo(x, y)
          else panelContext.lineTo(x, y)
        }
        panelContext.strokeStyle = color
        panelContext.lineWidth = 5
        panelContext.stroke()
      }
      drawWave(174, 'rgba(100, 225, 247, 0.98)', 31)
      drawWave(320, 'rgba(119, 225, 166, 0.94)', 23)
      panelContext.fillStyle = 'rgba(214, 242, 246, 0.96)'
      panelContext.font = '600 20px Cascadia Code, monospace'
      panelContext.fillText('42%', 540, 105)
      panelContext.fillText('68%', 540, 250)
      panelContext.fillStyle = 'rgba(109, 137, 144, 0.9)'
      panelContext.font = '500 15px Cascadia Code, monospace'
      panelContext.fillText('LAST UPDATE  00:02', 38, 394)
    }

    const panelTexture = new THREE.CanvasTexture(panelCanvas)
    panelTexture.colorSpace = THREE.SRGBColorSpace
    const panel = new THREE.Mesh(
      new THREE.PlaneGeometry(3.15, 2.06),
      new THREE.MeshBasicMaterial({ map: panelTexture, transparent: true, opacity: 0.9, side: THREE.DoubleSide }),
    )
    panel.position.set(2.65, 1.22, 0.3)
    panel.rotation.y = -0.28
    world.add(panel)

    const panelFrame = new THREE.LineSegments(
      new THREE.EdgesGeometry(new THREE.BoxGeometry(3.22, 2.13, 0.04)),
      new THREE.LineBasicMaterial({ color: 0x84e8f6, transparent: true, opacity: 0.72 }),
    )
    panelFrame.position.copy(panel.position)
    panelFrame.rotation.copy(panel.rotation)
    world.add(panelFrame)

    const paths = [
      new THREE.CatmullRomCurve3([
        new THREE.Vector3(-2.55, -0.9, 1.5),
        new THREE.Vector3(-1.3, -0.25, 2.15),
        new THREE.Vector3(0.35, 0.1, 1.75),
        new THREE.Vector3(2.1, 0.8, 1.15),
      ]),
      new THREE.CatmullRomCurve3([
        new THREE.Vector3(-2.15, 1.55, 0.4),
        new THREE.Vector3(-0.8, 1.9, 1.2),
        new THREE.Vector3(0.75, 1.45, 1.75),
        new THREE.Vector3(2.55, 1.45, 0.5),
      ]),
      new THREE.CatmullRomCurve3([
        new THREE.Vector3(-1.4, -1.65, 0.85),
        new THREE.Vector3(-0.3, -1.25, 2.2),
        new THREE.Vector3(1.05, -0.55, 1.7),
        new THREE.Vector3(2.8, -0.2, 0.1),
      ]),
    ]

    paths.forEach((path) => {
      const line = new THREE.Line(
        new THREE.BufferGeometry().setFromPoints(path.getPoints(90)),
        new THREE.LineBasicMaterial({ color: 0x68def2, transparent: true, opacity: 0.66 }),
      )
      world.add(line)
    })

    const beads = Array.from({ length: 18 }, (_, index) => {
      const mesh = new THREE.Mesh(new THREE.SphereGeometry(index % 3 === 0 ? 0.045 : 0.026, 8, 8), cyan)
      world.add(mesh)
      return { mesh, path: paths[index % paths.length], offset: index / 18 }
    })

    const particleCount = 620
    const particlePositions = new Float32Array(particleCount * 3)
    for (let index = 0; index < particleCount; index += 1) {
      particlePositions[index * 3] = (Math.random() - 0.5) * 10
      particlePositions[index * 3 + 1] = (Math.random() - 0.5) * 6
      particlePositions[index * 3 + 2] = (Math.random() - 0.5) * 6
    }
    const particleGeometry = new THREE.BufferGeometry()
    particleGeometry.setAttribute('position', new THREE.BufferAttribute(particlePositions, 3))
    const particles = new THREE.Points(
      particleGeometry,
      new THREE.PointsMaterial({ color: 0x9cecf6, size: 0.028, transparent: true, opacity: 0.68, sizeAttenuation: true }),
    )
    world.add(particles)

    const glyphTextures: InstanceType<typeof THREE.CanvasTexture>[] = []
    const glyphs = ['01', '10', 'CPU 42%', 'NET 8.4M'].map((label, index) => {
      const glyphCanvas = document.createElement('canvas')
      glyphCanvas.width = 256
      glyphCanvas.height = 64
      const context = glyphCanvas.getContext('2d')
      if (context) {
        context.font = '600 25px Cascadia Code, monospace'
        context.fillStyle = index < 2 ? 'rgba(119, 225, 246, 0.9)' : 'rgba(150, 190, 199, 0.78)'
        context.fillText(label, 8, 42)
      }
      const texture = new THREE.CanvasTexture(glyphCanvas)
      texture.colorSpace = THREE.SRGBColorSpace
      glyphTextures.push(texture)
      const sprite = new THREE.Sprite(new THREE.SpriteMaterial({ map: texture, transparent: true, opacity: 0.78, depthWrite: false }))
      const positions = [
        [-2.5, 1.15, 1.6],
        [2.35, -1.3, 1.75],
        [-1.9, -1.25, 1.9],
        [2.55, 0.05, 1.4],
      ]
      const [x, y, z] = positions[index]
      sprite.position.set(x, y, z)
      sprite.scale.set(index < 2 ? 0.55 : 1.15, 0.28, 1)
      world.add(sprite)
      return { sprite, baseY: y, phase: index * 1.7 }
    })

    const floor = new THREE.Mesh(
      new THREE.PlaneGeometry(14, 10),
      new THREE.MeshStandardMaterial({ color: 0x070c0f, metalness: 0.62, roughness: 0.58, transparent: true, opacity: 0.78 }),
    )
    floor.rotation.x = -Math.PI / 2
    floor.position.y = -2.06
    floor.receiveShadow = true
    scene.add(floor)

    const grid = new THREE.GridHelper(16, 28, 0x2e9fb2, 0x17353d)
    grid.position.y = -2.05
    const gridMaterials = Array.isArray(grid.material) ? grid.material : [grid.material]
    gridMaterials.forEach((material) => {
      material.transparent = true
      material.opacity = 0.22
    })
    scene.add(grid)

    scene.add(new THREE.HemisphereLight(0xc0edf4, 0x05070a, 1.08))
    const keyLight = new THREE.DirectionalLight(0xe7f8ff, 3.8)
    keyLight.position.set(2.5, 5, 6)
    keyLight.castShadow = true
    scene.add(keyLight)
    const rimLight = new THREE.PointLight(0x48c7ff, 24, 12, 1.65)
    rimLight.position.set(-2.8, 0.5, 3.5)
    scene.add(rimLight)
    const panelLight = new THREE.PointLight(0x63e6d2, 14, 9, 1.8)
    panelLight.position.set(3, 1, 2)
    scene.add(panelLight)
    const backLight = new THREE.PointLight(0xa6e8ff, 14, 10, 1.8)
    backLight.position.set(0, 2.5, -3)
    scene.add(backLight)

    const reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)')
    let isInViewport = true
    let pointerX = 0
    let pointerY = 0
    let frame = 0
    let animating = false
    let worldBaseY = -0.02
    const clock = new THREE.Clock()

    const resize = () => {
      if (!host.value) return
      const width = host.value.clientWidth
      const height = host.value.clientHeight
      renderer.setSize(width, height, false)
      camera.aspect = width / Math.max(height, 1)
      const isCompact = width < 760
      camera.position.x = isCompact ? 0.8 : 0.1
      camera.position.z = isCompact ? 11.5 : 10.2
      world.scale.setScalar(isCompact ? 0.76 : 1)
      world.position.x = isCompact ? 0.9 : 1.45
      worldBaseY = isCompact ? 0.45 : -0.02
      world.position.y = worldBaseY
      panel.visible = !isCompact
      panelFrame.visible = !isCompact
      glyphs.forEach(({ sprite }, index) => { sprite.visible = !isCompact || index < 2 })
      camera.updateProjectionMatrix()
      renderer.render(scene, camera)
    }

    const onPointerMove = (event: PointerEvent) => {
      if (!host.value || reduceMotion.matches) return
      const bounds = host.value.getBoundingClientRect()
      pointerX = ((event.clientX - bounds.left) / bounds.width - 0.5) * 0.22
      pointerY = ((event.clientY - bounds.top) / bounds.height - 0.5) * 0.16
    }

    const render = () => {
      if (!animating || !isInViewport || document.hidden || reduceMotion.matches) {
        animating = false
        frame = 0
        renderer.render(scene, camera)
        return
      }
      const elapsed = clock.getElapsedTime()
      world.rotation.y += (pointerX - world.rotation.y) * 0.035
      world.rotation.x += (-pointerY - world.rotation.x) * 0.035
      world.position.y = worldBaseY + Math.sin(elapsed * 0.6) * 0.055
      particles.rotation.y = elapsed * 0.018
      cyan.opacity = 0.84 + Math.sin(elapsed * 2.2) * 0.14
      green.opacity = 0.82 + Math.sin(elapsed * 2.6 + 0.8) * 0.16
      beads.forEach(({ mesh, path }, index) => {
        const progress = (elapsed * 0.09 + index / beads.length) % 1
        mesh.position.copy(path.getPointAt(progress))
      })
      glyphs.forEach(({ sprite, baseY, phase }) => {
        sprite.position.y = baseY + Math.sin(elapsed * 0.55 + phase) * 0.08
      })
      renderer.render(scene, camera)
      frame = window.requestAnimationFrame(render)
    }

    const syncAnimation = () => {
      if (frame) window.cancelAnimationFrame(frame)
      frame = 0
      animating = isInViewport && !document.hidden && !reduceMotion.matches
      if (animating) {
        clock.start()
        render()
      } else {
        renderer.render(scene, camera)
      }
    }

    const onVisibilityChange = () => syncAnimation()

    const observer = new IntersectionObserver(([entry]) => {
      isInViewport = entry.isIntersecting
      syncAnimation()
    }, { threshold: 0.02 })
    observer.observe(host.value)
    const resizeObserver = new ResizeObserver(resize)
    resizeObserver.observe(host.value)
    host.value.addEventListener('pointermove', onPointerMove, { passive: true })
    document.addEventListener('visibilitychange', onVisibilityChange)
    reduceMotion.addEventListener('change', syncAnimation)

    resize()
    syncAnimation()

    disposeScene = () => {
      window.cancelAnimationFrame(frame)
      observer.disconnect()
      resizeObserver.disconnect()
      host.value?.removeEventListener('pointermove', onPointerMove)
      document.removeEventListener('visibilitychange', onVisibilityChange)
      reduceMotion.removeEventListener('change', syncAnimation)
      panelTexture.dispose()
      glyphTextures.forEach((texture) => texture.dispose())
      scene.traverse((object) => {
        if (object instanceof THREE.Mesh || object instanceof THREE.Points || object instanceof THREE.Line || object instanceof THREE.LineSegments) {
          object.geometry?.dispose()
          const materials = Array.isArray(object.material) ? object.material : [object.material]
          materials.forEach((material) => material?.dispose())
        }
      })
      renderer.dispose()
      renderer.domElement.remove()
    }
  } catch {
    failed.value = true
  }
})

onBeforeUnmount(() => disposeScene())
</script>

<template>
  <div ref="host" class="hero-scene" aria-hidden="true">
    <img v-if="failed" src="/brand-icon.png" alt="" class="hero-scene-fallback">
  </div>
</template>
