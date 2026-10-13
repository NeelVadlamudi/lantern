// "Boston, 1775" period-map basemap on OpenFreeMap vector tiles (OpenMapTiles schema; free, no key).
// Parchment land, pale blue-grey water with a faint darker coastline, thin sepia streets, a faint
// sage wash for parks, buildings barely there, place names in EB Garamond letterspaced caps.
// Low contrast throughout so the subway lines sit on top comfortably.
// Glyphs: OpenFreeMap hosts only Noto Sans, so the EB Garamond label glyphs are built from the
// same font files as the UI (assets/glyphs/, fontnik SDF) and served with the board.
export const BASEMAP_ATTRIBUTION =
  '<a href="https://openfreemap.org" target="_blank" rel="noopener">OpenFreeMap</a> &copy; <a href="https://www.openmaptiles.org/" target="_blank" rel="noopener">OpenMapTiles</a> Data from <a href="https://www.openstreetmap.org/copyright" target="_blank" rel="noopener">OpenStreetMap</a>';

export const MAP_FONT = ["EB Garamond Regular"];
export const MAP_FONT_ITALIC = ["EB Garamond Italic"];
export const PAPER = "#F2EAD8";
export const INK = "#2B2118";
const NAME = ["coalesce", ["get", "name:en"], ["get", "name"]];
const glyphsUrl = () => `${new URL("assets/glyphs/", document.baseURI).href}{fontstack}/{range}.pbf`;

export function basemapStyle() {
  return {
    version: 8,
    glyphs: glyphsUrl(),
    sources: {
      omt: { type: "vector", url: "https://tiles.openfreemap.org/planet", attribution: BASEMAP_ATTRIBUTION },
    },
    layers: [
      { id: "bg", type: "background", paint: { "background-color": PAPER } },
      {
        id: "landcover-wood", type: "fill", source: "omt", "source-layer": "landcover",
        filter: ["in", ["get", "class"], ["literal", ["wood", "grass"]]], paint: { "fill-color": "#DEDDC2", "fill-opacity": 0.45 },
      },
      { id: "park", type: "fill", source: "omt", "source-layer": "park", paint: { "fill-color": "#D9DCC0", "fill-opacity": 0.55 } },
      { id: "water", type: "fill", source: "omt", "source-layer": "water", paint: { "fill-color": "#C9D3D3" } },
      // Coastline: the water polygons' outline, a faint darker wash line.
      {
        id: "water-edge", type: "line", source: "omt", "source-layer": "water",
        paint: { "line-color": "#7E8E8E", "line-opacity": 0.55, "line-width": ["interpolate", ["linear"], ["zoom"], 9, 0.4, 14, 0.9] },
      },
      {
        id: "waterway", type: "line", source: "omt", "source-layer": "waterway",
        paint: { "line-color": "#B7C4C4", "line-width": ["interpolate", ["linear"], ["zoom"], 10, 0.5, 15, 2] },
      },
      {
        id: "building", type: "fill", source: "omt", "source-layer": "building", minzoom: 15,
        paint: { "fill-color": "#E7DDC8", "fill-opacity": 0.45, "fill-outline-color": "rgba(107,91,72,0.12)" },
      },
      {
        id: "road-minor", type: "line", source: "omt", "source-layer": "transportation", minzoom: 12,
        filter: ["in", ["get", "class"], ["literal", ["minor", "service", "tertiary", "secondary"]]],
        layout: { "line-cap": "round", "line-join": "round" },
        paint: {
          "line-color": "#6B5B48",
          "line-opacity": ["interpolate", ["linear"], ["zoom"], 12, 0.12, 16, 0.22],
          "line-width": ["interpolate", ["linear"], ["zoom"], 12, 0.3, 16, 1.2],
        },
      },
      {
        id: "road-major", type: "line", source: "omt", "source-layer": "transportation",
        filter: ["in", ["get", "class"], ["literal", ["motorway", "trunk", "primary"]]],
        layout: { "line-cap": "round", "line-join": "round" },
        paint: {
          "line-color": "#6B5B48",
          "line-opacity": ["interpolate", ["linear"], ["zoom"], 9, 0.16, 14, 0.3],
          "line-width": ["interpolate", ["linear"], ["zoom"], 9, 0.35, 13, 0.8, 16, 2],
        },
      },
      {
        id: "water-name", type: "symbol", source: "omt", "source-layer": "water_name", minzoom: 11,
        layout: { "text-field": NAME, "text-font": MAP_FONT_ITALIC, "text-size": 12.5, "text-letter-spacing": 0.12 },
        paint: { "text-color": "#5B6B6B", "text-halo-color": "rgba(201,211,211,0.8)", "text-halo-width": 1 },
      },
      {
        id: "place", type: "symbol", source: "omt", "source-layer": "place",
        filter: ["in", ["get", "class"], ["literal", ["city", "town", "suburb", "neighbourhood"]]],
        layout: {
          "text-field": NAME,
          "text-font": MAP_FONT,
          "text-transform": "uppercase",
          "text-size": ["match", ["get", "class"], "city", 13, "town", 11, 10],
          "text-letter-spacing": 0.16,
          "text-max-width": 9,
        },
        paint: { "text-color": "#6B5B48", "text-opacity": 0.85, "text-halo-color": PAPER, "text-halo-width": 1.4 },
      },
    ],
  };
}
