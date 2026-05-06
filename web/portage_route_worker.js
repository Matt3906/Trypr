'use strict';

const graphCache = new Map();

self.onmessage = (event) => {
  const data = event && event.data ? event.data : {};
  const type = data.type;
  const requestId = data.requestId;

  try {
    if (type === 'cacheGraph') {
      graphCache.set(String(data.graphKey || ''), {
        adjacency: normalizeAdjacency(data.adjacency),
      });
      self.postMessage({
        type: 'cacheGraphResult',
        requestId,
      });
      return;
    }

    if (type === 'solveLeg') {
      const graphKey = String(data.graphKey || '');
      const graph = graphCache.get(graphKey);
      const result = graph
        ? solveLeg({
            adjacency: graph.adjacency,
            startCandidates: Array.isArray(data.startCandidates)
              ? data.startCandidates
              : [],
            endCandidates: Array.isArray(data.endCandidates)
              ? data.endCandidates
              : [],
            timeBudgetMs: Number(data.timeBudgetMs) || 12000,
          })
        : { missingGraph: true };
      self.postMessage({
        type: 'solveLegResult',
        requestId,
        result,
      });
      return;
    }

    if (type === 'disposeGraph') {
      graphCache.delete(String(data.graphKey || ''));
      self.postMessage({
        type: 'disposeGraphResult',
        requestId,
      });
    }
  } catch (error) {
    self.postMessage({
      type: 'workerError',
      requestId,
      error: error && error.message ? String(error.message) : String(error),
      stack: error && error.stack ? String(error.stack) : '',
    });
  }
};

function normalizeAdjacency(adjacency) {
  if (!Array.isArray(adjacency)) return [];
  return adjacency.map((row) => {
    if (!Array.isArray(row)) return [];
    return row
      .map((edge) => {
        if (!Array.isArray(edge) || edge.length < 2) return null;
        return [edge[0] | 0, Number(edge[1])];
      })
      .filter(Boolean);
  });
}

function solveLeg({
  adjacency,
  startCandidates,
  endCandidates,
  timeBudgetMs,
}) {
  if (!Array.isArray(adjacency) || adjacency.length === 0) {
    return { missingGraph: true };
  }

  const starts = normalizeCandidates(startCandidates);
  const ends = normalizeCandidates(endCandidates);
  if (starts.length === 0 || ends.length === 0) return null;

  const endNodeSet = new Set(ends.map((candidate) => candidate.index));
  const deadline = Date.now() + Math.max(1000, timeBudgetMs);
  const treeCache = new Map();
  let best = null;
  let timedOut = false;

  for (let sOrd = 0; sOrd < starts.length; sOrd += 1) {
    const startCandidate = starts[sOrd];
    let tree = treeCache.get(startCandidate.index);
    if (!tree) {
      tree = shortestTree(
        startCandidate.index,
        adjacency,
        endNodeSet,
        deadline,
      );
      treeCache.set(startCandidate.index, tree);
    }
    timedOut = timedOut || tree.timedOut;

    for (let eOrd = 0; eOrd < ends.length; eOrd += 1) {
      const endCandidate = ends[eOrd];
      const graphMeters = tree.dist[endCandidate.index];
      if (!Number.isFinite(graphMeters)) continue;
      const score =
        startCandidate.totalConnectorMeters +
        graphMeters +
        endCandidate.totalConnectorMeters;
      if (!best || score < best.score) {
        const pathIndices = reconstructPath(
          startCandidate.index,
          endCandidate.index,
          tree.prev,
        );
        if (pathIndices.length === 0) continue;
        best = {
          score,
          startOrdinal: sOrd,
          endOrdinal: eOrd,
          graphMeters,
          pathIndices,
        };
      }
    }

    if (Date.now() > deadline) {
      timedOut = true;
      break;
    }
  }

  if (!best) {
    return {
      timedOut,
    };
  }

  return {
    startOrdinal: best.startOrdinal,
    endOrdinal: best.endOrdinal,
    graphMeters: best.graphMeters,
    pathIndices: best.pathIndices,
    timedOut,
  };
}

function normalizeCandidates(candidates) {
  if (!Array.isArray(candidates)) return [];
  return candidates
    .map((candidate) => ({
      index: candidate && candidate.index != null ? candidate.index | 0 : -1,
      totalConnectorMeters:
        candidate && candidate.totalConnectorMeters != null
          ? Number(candidate.totalConnectorMeters)
          : Number.POSITIVE_INFINITY,
    }))
    .filter(
      (candidate) =>
        candidate.index >= 0 && Number.isFinite(candidate.totalConnectorMeters),
    );
}

function shortestTree(source, adjacency, stopNodes, deadline) {
  const nodeCount = adjacency.length;
  const dist = new Array(nodeCount).fill(Number.POSITIVE_INFINITY);
  const prev = new Array(nodeCount).fill(-1);
  if (source < 0 || source >= nodeCount) {
    return { dist, prev, timedOut: false };
  }

  dist[source] = 0;
  const pendingStops = new Set(stopNodes);
  const heap = new MinNodeHeap();
  heap.add(source, 0);
  let expansions = 0;
  let timedOut = false;

  while (!heap.isEmpty()) {
    if ((expansions & 255) === 0 && Date.now() > deadline) {
      timedOut = true;
      break;
    }

    const current = heap.removeFirst();
    const node = current.node;
    const bestMeters = current.meters;
    if (bestMeters > dist[node] + 1e-9) {
      expansions += 1;
      continue;
    }

    if (pendingStops.delete(node) && pendingStops.size === 0) {
      break;
    }

    const edges = adjacency[node] || [];
    for (let i = 0; i < edges.length; i += 1) {
      const edge = edges[i];
      const to = edge[0] | 0;
      const meters = Number(edge[1]);
      if (to < 0 || to >= nodeCount || !Number.isFinite(meters)) continue;
      const alt = dist[node] + meters;
      if (alt + 1e-9 < dist[to]) {
        dist[to] = alt;
        prev[to] = node;
        heap.add(to, alt);
      }
    }

    expansions += 1;
  }

  return { dist, prev, timedOut };
}

function reconstructPath(start, end, prev) {
  if (
    start < 0 ||
    end < 0 ||
    start >= prev.length ||
    end >= prev.length
  ) {
    return [];
  }

  const reversed = [];
  let cursor = end;
  while (cursor >= 0) {
    reversed.push(cursor);
    if (cursor === start) break;
    cursor = prev[cursor];
    if (cursor < 0) return [];
  }
  reversed.reverse();
  return reversed;
}

class MinNodeHeap {
  constructor() {
    this.items = [];
  }

  isEmpty() {
    return this.items.length === 0;
  }

  add(node, meters) {
    this.items.push({ node, meters });
    let index = this.items.length - 1;
    while (index > 0) {
      const parent = (index - 1) >> 1;
      if (this.items[parent].meters <= this.items[index].meters) break;
      const tmp = this.items[parent];
      this.items[parent] = this.items[index];
      this.items[index] = tmp;
      index = parent;
    }
  }

  removeFirst() {
    const first = this.items[0];
    const last = this.items.pop();
    if (this.items.length === 0) {
      return first;
    }

    this.items[0] = last;
    let index = 0;
    while (true) {
      const left = (index << 1) + 1;
      const right = left + 1;
      let smallest = index;
      if (
        left < this.items.length &&
        this.items[left].meters < this.items[smallest].meters
      ) {
        smallest = left;
      }
      if (
        right < this.items.length &&
        this.items[right].meters < this.items[smallest].meters
      ) {
        smallest = right;
      }
      if (smallest === index) break;
      const tmp = this.items[index];
      this.items[index] = this.items[smallest];
      this.items[smallest] = tmp;
      index = smallest;
    }
    return first;
  }
}
