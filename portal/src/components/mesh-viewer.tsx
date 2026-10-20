"use client";

import { useEffect, useRef, useState } from "react";
import * as THREE from "three";
import { OrbitControls } from "three/addons/controls/OrbitControls.js";
import { PLYLoader } from "three/addons/loaders/PLYLoader.js";
import { STLLoader } from "three/addons/loaders/STLLoader.js";
import { Box, Grid3x3, Palette, Ruler, RotateCcw, Loader2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import { cn } from "@/lib/utils";

type ViewName = "face" | "gauche" | "droite" | "dessous";

/**
 * Visionneuse 3D (three.js). Repère des fichiers : x = gauche du patient, y = haut, z = antérieur, en mm.
 * « Profil gauche » = on regarde le côté gauche du patient (caméra en +x).
 */
export function MeshViewer({ url, format }: { url: string; format: "PLY" | "STL" }) {
  const mountRef = useRef<HTMLDivElement>(null);
  const api = useRef<{
    setColor: (on: boolean) => void;
    setWire: (on: boolean) => void;
    setView: (v: ViewName) => void;
    setMeasure: (on: boolean) => void;
    clearMeasure: () => void;
  } | null>(null);

  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [hasColor, setHasColor] = useState(false);
  const [color, setColor] = useState(true);
  const [wire, setWire] = useState(false);
  const [measure, setMeasure] = useState(false);
  const [distance, setDistance] = useState<number | null>(null);
  const [stats, setStats] = useState<{ v: number; t: number } | null>(null);

  useEffect(() => {
    const mount = mountRef.current;
    if (!mount) return;
    let disposed = false;

    const scene = new THREE.Scene();
    scene.background = new THREE.Color(0x14181c);
    const camera = new THREE.PerspectiveCamera(35, 1, 1, 5000);
    const renderer = new THREE.WebGLRenderer({ antialias: true });
    renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2));
    renderer.outputColorSpace = THREE.SRGBColorSpace;
    mount.appendChild(renderer.domElement);

    scene.add(new THREE.HemisphereLight(0xffffff, 0x444444, 1.6));
    const headLight = new THREE.DirectionalLight(0xffffff, 1.4);
    camera.add(headLight);
    headLight.position.set(0.3, 0.4, 1);
    scene.add(camera);

    const controls = new OrbitControls(camera, renderer.domElement);
    controls.enableDamping = true;

    const material = new THREE.MeshStandardMaterial({
      color: 0xffffff,
      roughness: 0.75,
      metalness: 0,
      vertexColors: false,
      side: THREE.DoubleSide,
    });
    let mesh: THREE.Mesh | null = null;
    let radius = 120;

    // Mesure
    const markers = new THREE.Group();
    scene.add(markers);
    const picked: THREE.Vector3[] = [];
    let measuring = false;
    const raycaster = new THREE.Raycaster();
    const pointer = new THREE.Vector2();
    let downAt: { x: number; y: number } | null = null;

    function clearMeasure() {
      picked.length = 0;
      markers.clear();
      setDistance(null);
    }

    function addMarker(p: THREE.Vector3) {
      const s = new THREE.Mesh(
        new THREE.SphereGeometry(radius * 0.012, 16, 16),
        new THREE.MeshBasicMaterial({ color: 0xff3b30, depthTest: false }),
      );
      s.renderOrder = 10;
      s.position.copy(p);
      markers.add(s);
    }

    function onPointerDown(e: PointerEvent) {
      downAt = { x: e.clientX, y: e.clientY };
    }
    function onPointerUp(e: PointerEvent) {
      if (!measuring || !mesh || !downAt) return;
      if (Math.hypot(e.clientX - downAt.x, e.clientY - downAt.y) > 4) return; // c'était une rotation
      const rect = renderer.domElement.getBoundingClientRect();
      pointer.set(((e.clientX - rect.left) / rect.width) * 2 - 1, -((e.clientY - rect.top) / rect.height) * 2 + 1);
      raycaster.setFromCamera(pointer, camera);
      const hit = raycaster.intersectObject(mesh, false)[0];
      if (!hit) return;
      if (picked.length >= 2) clearMeasure();
      picked.push(hit.point.clone());
      addMarker(hit.point);
      if (picked.length === 2) {
        const line = new THREE.Line(
          new THREE.BufferGeometry().setFromPoints(picked),
          new THREE.LineBasicMaterial({ color: 0xff3b30, depthTest: false }),
        );
        line.renderOrder = 10;
        markers.add(line);
        setDistance(picked[0].distanceTo(picked[1]));
      }
    }
    renderer.domElement.addEventListener("pointerdown", onPointerDown);
    renderer.domElement.addEventListener("pointerup", onPointerUp);

    function setView(v: ViewName) {
      const d = radius * 3.2;
      const dirs: Record<ViewName, THREE.Vector3> = {
        face: new THREE.Vector3(0, 0, 1),
        gauche: new THREE.Vector3(1, 0, 0),
        droite: new THREE.Vector3(-1, 0, 0),
        dessous: new THREE.Vector3(0, -1, 0.35).normalize(),
      };
      camera.position.copy(dirs[v].multiplyScalar(d));
      camera.up.set(0, 1, 0);
      controls.target.set(0, 0, 0);
      controls.update();
    }

    function resize() {
      if (!mount) return;
      const w = mount.clientWidth;
      const h = mount.clientHeight;
      renderer.setSize(w, h);
      camera.aspect = w / Math.max(h, 1);
      camera.updateProjectionMatrix();
    }
    const ro = new ResizeObserver(resize);
    ro.observe(mount);
    resize();

    let frame = 0;
    const loop = () => {
      frame = requestAnimationFrame(loop);
      controls.update();
      renderer.render(scene, camera);
    };
    loop();

    (async () => {
      try {
        const res = await fetch(url, { credentials: "same-origin" });
        if (!res.ok) throw new Error(`Erreur ${res.status}`);
        const buf = await res.arrayBuffer();
        if (disposed) return;
        const geometry = format === "PLY" ? new PLYLoader().parse(buf) : new STLLoader().parse(buf);
        geometry.computeBoundingBox();
        const center = new THREE.Vector3();
        geometry.boundingBox!.getCenter(center);
        geometry.translate(-center.x, -center.y, -center.z);
        geometry.computeBoundingSphere();
        radius = geometry.boundingSphere!.radius;
        if (!geometry.getAttribute("normal")) geometry.computeVertexNormals();

        const colorAttr = geometry.getAttribute("color");
        if (colorAttr) {
          setHasColor(true);
          material.vertexColors = true;
        }
        mesh = new THREE.Mesh(geometry, material);
        scene.add(mesh);
        camera.near = radius / 50;
        camera.far = radius * 50;
        camera.updateProjectionMatrix();
        setView("face");
        setStats({ v: geometry.getAttribute("position").count, t: (geometry.index?.count ?? geometry.getAttribute("position").count) / 3 });
        setLoading(false);
      } catch (e) {
        setError(e instanceof Error ? e.message : "Erreur de chargement");
        setLoading(false);
      }
    })();

    api.current = {
      setColor: (on) => {
        material.vertexColors = on && !!mesh?.geometry.getAttribute("color");
        material.color.set(on ? 0xffffff : 0xd9c7b8);
        material.needsUpdate = true;
      },
      setWire: (on) => {
        material.wireframe = on;
      },
      setView,
      setMeasure: (on) => {
        measuring = on;
        renderer.domElement.style.cursor = on ? "crosshair" : "";
        if (!on) clearMeasure();
      },
      clearMeasure,
    };

    return () => {
      disposed = true;
      cancelAnimationFrame(frame);
      ro.disconnect();
      renderer.domElement.removeEventListener("pointerdown", onPointerDown);
      renderer.domElement.removeEventListener("pointerup", onPointerUp);
      controls.dispose();
      mesh?.geometry.dispose();
      material.dispose();
      renderer.dispose();
      mount.removeChild(renderer.domElement);
      api.current = null;
    };
  }, [url, format]);

  return (
    <div className="flex flex-col gap-2">
      <div className="flex flex-wrap items-center gap-2">
        <div className="flex gap-1 rounded-md border p-0.5">
          {(
            [
              ["face", "Face"],
              ["droite", "Profil droit"],
              ["gauche", "Profil gauche"],
              ["dessous", "Dessous"],
            ] as [ViewName, string][]
          ).map(([v, label]) => (
            <Button key={v} variant="ghost" size="sm" onClick={() => api.current?.setView(v)}>
              {label}
            </Button>
          ))}
        </div>
        <Button
          variant={color ? "secondary" : "outline"}
          size="sm"
          disabled={!hasColor}
          onClick={() => {
            setColor(!color);
            api.current?.setColor(!color);
          }}
        >
          <Palette /> {color ? "Couleur" : "Gris"}
        </Button>
        <Button
          variant={wire ? "secondary" : "outline"}
          size="sm"
          onClick={() => {
            setWire(!wire);
            api.current?.setWire(!wire);
          }}
        >
          <Grid3x3 /> Maillage
        </Button>
        <Button
          variant={measure ? "default" : "outline"}
          size="sm"
          onClick={() => {
            setMeasure(!measure);
            api.current?.setMeasure(!measure);
          }}
        >
          <Ruler /> Mesurer
        </Button>
        {measure && (
          <Button variant="ghost" size="sm" onClick={() => api.current?.clearMeasure()}>
            <RotateCcw /> Effacer
          </Button>
        )}
        <span className="ml-auto text-xs text-muted-foreground">
          {stats && `${stats.v.toLocaleString("fr-FR")} sommets · ${Math.round(stats.t).toLocaleString("fr-FR")} triangles`}
        </span>
      </div>
      <div className="relative h-[62vh] min-h-[380px] overflow-hidden rounded-lg border bg-[#14181c]">
        <div ref={mountRef} className="absolute inset-0" />
        {loading && (
          <div className="absolute inset-0 flex items-center justify-center gap-2 text-sm text-white/80">
            <Loader2 className="size-4 animate-spin" /> Chargement du modèle 3D…
          </div>
        )}
        {error && (
          <div className="absolute inset-0 flex items-center justify-center gap-2 text-sm text-red-300">
            <Box className="size-4" /> {error}
          </div>
        )}
        {measure && (
          <div
            className={cn(
              "absolute top-3 left-3 rounded-md bg-black/70 px-3 py-2 text-sm text-white",
              distance !== null && "font-semibold",
            )}
          >
            {distance === null ? "Cliquez deux points sur le visage" : `Distance : ${distance.toFixed(1)} mm`}
          </div>
        )}
      </div>
      <p className="text-xs text-muted-foreground">
        Clic gauche : rotation · clic droit : déplacement · molette : zoom. Mesures en millimètres, valables après validation de
        la précision du scanner.
      </p>
    </div>
  );
}
