function isRecord(x) {
    return !!x && typeof x === 'object' && !Array.isArray(x);
}
function isExactRef(x, project, snapshot) {
    return isRecord(x) && x.provider === 'beamcompass' && x.snapshot_schema_version === 2 &&
        x.project_id === project && x.snapshot_id === snapshot &&
        ['entity', 'relation', 'evidence'].includes(String(x.object_kind)) &&
        typeof x.object_id === 'string' && Array.isArray(x.evidence_ids) &&
        x.evidence_ids.every((id) => typeof id === 'string');
}
function exactKey(ref) {
    return `${ref.object_kind}:${ref.object_id}`;
}
const navigationFields = new Set(['project', 'snapshot', 'lens', 'budget',
    'focus_kind', 'focus_id', 'selected_kind', 'selected_id']);
function localParams(value) {
    if (typeof value !== 'string' || !value.startsWith('?') ||
        /[\u0000-\u001f#]/.test(value) || value.length >= 4096)
        return null;
    const query = new URLSearchParams(value.slice(1));
    const keys = Array.from(query.keys());
    if (new Set(keys).size !== keys.length || keys.some((key) => !navigationFields.has(key)))
        return null;
    return query;
}
/** Identity/URL consistency only: no source relation or budget inference in the UI. */
function safeLocalHref(value, ref, base) {
    const query = localParams(value);
    if (!query || query.get('project') !== ref.project_id ||
        query.get('snapshot') !== ref.snapshot_id ||
        query.get('selected_kind') !== ref.object_kind ||
        query.get('selected_id') !== ref.object_id)
        return false;
    return ['project', 'snapshot', 'lens', 'budget', 'focus_kind', 'focus_id'].every((key) => query.get(key) === base.get(key));
}
/** Strict structural and identity-consistency check, not a semantic recomputation. */
export function assertNavigatorView(input) {
    if (!isRecord(input) || input.format !== 'beamcompass.navigator.view' ||
        input.schema_version !== 1 || input.snapshot_schema_version !== 2 ||
        typeof input.project_id !== 'string' || typeof input.snapshot_id !== 'string' ||
        !['available', 'unavailable'].includes(String(input.status)) ||
        !['behavior', 'effects', 'state', 'failure'].includes(String(input.lens)) ||
        !Number.isInteger(input.budget) || Number(input.budget) < 1 || Number(input.budget) > 256 ||
        !isRecord(input.stage) || !Array.isArray(input.stage.nodes) ||
        !Array.isArray(input.stage.edges) || !Array.isArray(input.diagnostics)) {
        throw new Error('Unsupported or malformed navigator contract');
    }
    const project = input.project_id;
    const snapshot = input.snapshot_id;
    if (input.status === 'unavailable') {
        if (input.stage.nodes.length !== 0 || input.stage.edges.length !== 0 ||
            input.projection !== null || input.diagnostics.length === 0) {
            throw new Error('Unavailable target cannot have a substitute stage');
        }
        return input;
    }
    const projection = input.projection;
    const navigation = input.navigation;
    if (!isRecord(navigation) || !isRecord(navigation.lenses)) {
        throw new Error('Missing core navigation URLs');
    }
    const self = localParams(navigation.self);
    if (!self || self.get('project') !== input.project_id ||
        self.get('snapshot') !== input.snapshot_id ||
        self.get('lens') !== input.lens || self.get('budget') !== String(input.budget)) {
        throw new Error('Core navigation URLs disagree with identity');
    }
    const lenses = ['behavior', 'effects', 'state', 'failure'];
    const lensUrls = navigation.lenses;
    if (lenses.some((lens) => {
        const target = localParams(lensUrls[lens]);
        return !target || target.get('lens') !== lens ||
            ['project', 'snapshot', 'budget', 'focus_kind', 'focus_id', 'selected_kind', 'selected_id'].some((key) => target.get(key) !== self.get(key));
    }))
        throw new Error('Core lens URLs disagree with identity');
    for (const field of ['zoom_in', 'zoom_out']) {
        const target = localParams(navigation[field]);
        if (!target || !['project', 'snapshot', 'lens', 'focus_kind', 'focus_id', 'selected_kind', 'selected_id']
            .every((key) => target.get(key) === self.get(key))) {
            throw new Error('Core zoom URLs disagree with identity');
        }
    }
    if (!isRecord(projection) || !Array.isArray(projection.visible) ||
        !Array.isArray(projection.omitted) || !Array.isArray(projection.collapsed) ||
        !Array.isArray(projection.unknown) || !isRecord(projection.receipt) ||
        !isRecord(projection.receipt.counts)) {
        throw new Error('Missing core projection receipt');
    }
    const visible = projection.visible;
    const ids = visible.map((x) => {
        if (!isExactRef(x, project, snapshot))
            throw new Error('Unpinned projection identity');
        return exactKey(x);
    });
    if (new Set(ids).size !== ids.length ||
        projection.receipt.counts.visible !== visible.length ||
        projection.receipt.counts.omitted !== projection.omitted.length ||
        projection.receipt.counts.collapsed !== projection.collapsed.length ||
        projection.receipt.counts.unknown !== projection.unknown.length) {
        throw new Error('Core receipt count/identity conflict');
    }
    const visibleSet = new Set(ids);
    const nodes = input.stage.nodes;
    if (nodes.length !== visible.length || nodes.some((n) => !isRecord(n) || !isExactRef(n.reference, project, snapshot) ||
        n.id !== exactKey(n.reference) || n.kind !== n.reference.object_kind ||
        !visibleSet.has(String(n.id)) || typeof n.label !== 'string' ||
        !safeLocalHref(n.href, n.reference, self))) {
        throw new Error('Stage disagrees with core visible identities');
    }
    for (const value of input.stage.edges) {
        if (!isRecord(value) || !isExactRef(value.reference, project, snapshot) ||
            value.reference.object_kind !== 'relation' || !visibleSet.has(exactKey(value.reference)) ||
            value.id !== value.reference.object_id ||
            !String(value.source).startsWith('entity:') ||
            !String(value.target).startsWith('entity:') ||
            !visibleSet.has(String(value.source)) || !visibleSet.has(String(value.target))) {
            throw new Error('Unproven/missing semantic connector');
        }
    }
    for (const kind of ['omitted', 'collapsed', 'unknown']) {
        for (const entry of projection[kind]) {
            if (!isRecord(entry) || !isExactRef(entry.reference, project, snapshot) ||
                typeof entry.reason !== 'string')
                throw new Error('Unpinned receipt entry');
        }
    }
    if (input.selection !== null && !isExactRef(input.selection, project, snapshot)) {
        throw new Error('Unpinned selected source record');
    }
    if (input.drawer !== null) {
        if (!isRecord(input.drawer) || !isRecord(input.drawer.reference) ||
            !isExactRef(input.drawer.reference, project, snapshot) || !input.selection ||
            exactKey(input.drawer.reference) !== exactKey(input.selection) ||
            !Array.isArray(input.drawer.evidence)) {
            throw new Error('Drawer identity not pinned to selection');
        }
        for (const item of input.drawer.evidence) {
            if (!isRecord(item) || !isExactRef(item.reference, project, snapshot) ||
                item.reference.object_kind !== 'evidence' || item.id !== item.reference.object_id ||
                !safeLocalHref(item.href, item.reference, self) ||
                !isRecord(item.anchor) || typeof item.anchor.path !== 'string' ||
                item.anchor.path.startsWith('/') || item.anchor.path.split('/').some((segment) => segment === '' || segment === '.' || segment === '..')) {
                throw new Error('Drawer evidence does not match exact source reference');
            }
        }
    }
    return input;
}
function decode(viewBase64) {
    const normalized = viewBase64.replace(/-/g, '+').replace(/_/g, '/');
    const raw = atob(normalized);
    const bytes = Uint8Array.from(raw, (ch) => ch.charCodeAt(0));
    return JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes));
}
function positionEdges(canvas, nodes, view) {
    const rect = nodes.getBoundingClientRect();
    const width = Math.max(1, Math.ceil(rect.width));
    const height = Math.max(1, Math.ceil(rect.height));
    const scale = window.devicePixelRatio || 1;
    canvas.width = Math.ceil(width * scale);
    canvas.height = Math.ceil(height * scale);
    canvas.style.width = `${width}px`;
    canvas.style.height = `${height}px`;
    const ctx = canvas.getContext('2d');
    if (!ctx)
        return;
    ctx.scale(scale, scale);
    ctx.strokeStyle = '#b4d2e6';
    ctx.lineWidth = 1.4;
    ctx.globalAlpha = .52;
    const cards = Array.from(nodes.querySelectorAll('a[data-record-key]'));
    const lookup = new Map(cards.map((card) => [card.dataset.recordKey || '', card]));
    for (const edge of view.stage.edges) {
        const start = lookup.get(edge.source)?.getBoundingClientRect();
        const end = lookup.get(edge.target)?.getBoundingClientRect();
        if (!start || !end)
            continue;
        ctx.beginPath();
        ctx.moveTo(start.left - rect.left + start.width / 2, start.top - rect.top + start.height / 2);
        ctx.lineTo(end.left - rect.left + end.width / 2, end.top - rect.top + end.height / 2);
        if (edge.resolution === 'unresolved')
            ctx.setLineDash([4, 4]);
        else
            ctx.setLineDash([]);
        ctx.stroke();
    }
}
/** Canvas is decoration; screen-reader and keyboard operation use native links. */
export function mountStage(host) {
    const cleanups = [];
    host.replaceChildren();
    try {
        const payload = host.dataset.view;
        if (!payload)
            throw new Error('Missing core navigator payload');
        const view = assertNavigatorView(decode(payload));
        if (view.status === 'unavailable') {
            throw new Error(view.diagnostics.map((item) => item.code).join(', '));
        }
        const canvas = document.createElement('canvas');
        canvas.className = 'stage-connections';
        canvas.setAttribute('aria-hidden', 'true');
        const list = document.createElement('ul');
        list.className = 'stage-nodes';
        list.setAttribute('aria-label', 'Source-backed records');
        for (const node of view.stage.nodes) {
            const li = document.createElement('li');
            const link = document.createElement('a');
            link.className = 'stage-card';
            link.href = node.href;
            link.dataset.recordKey = node.id;
            if (view.selection && exactKey(view.selection) === node.id) {
                link.setAttribute('aria-current', 'true');
                link.classList.add('selected');
            }
            const kind = document.createElement('span');
            kind.className = 'stage-kind';
            kind.textContent = `${node.kind} · ${node.detail}`;
            const name = document.createElement('strong');
            name.textContent = node.label;
            const source = document.createElement('small');
            source.textContent = `${node.epistemic_status} · ${node.resolution || 'source-only'}`;
            link.append(kind, name, source);
            li.append(link);
            list.append(li);
        }
        const empty = document.createElement('p');
        empty.textContent = 'No records visible under this exact source budget and lens; inspect receipts.';
        empty.hidden = view.stage.nodes.length > 0;
        host.append(canvas, list, empty);
        const redraw = () => positionEdges(canvas, list, view);
        const observer = new ResizeObserver(redraw);
        observer.observe(list);
        cleanups.push(() => observer.disconnect());
        redraw();
        const keyboard = (event) => {
            if (!['ArrowDown', 'ArrowRight', 'ArrowUp', 'ArrowLeft', 'Home', 'End'].includes(event.key))
                return;
            const links = Array.from(list.querySelectorAll('a.stage-card'));
            const current = links.indexOf(document.activeElement);
            if (!links.length || (current === -1 && event.target !== list))
                return;
            const next = event.key === 'Home' ? 0 : event.key === 'End' ? links.length - 1 :
                event.key === 'ArrowDown' || event.key === 'ArrowRight' ?
                    (current + 1) % links.length : (current - 1 + links.length) % links.length;
            event.preventDefault();
            links[next].focus();
        };
        list.addEventListener('keydown', keyboard);
        cleanups.push(() => list.removeEventListener('keydown', keyboard));
        // Focus is not reset after LiveView patches: keyboard users retain position.
    }
    catch (error) {
        const diagnostic = document.createElement('p');
        diagnostic.setAttribute('role', 'alert');
        diagnostic.className = 'stage-error';
        diagnostic.textContent = `Navigator contract unavailable: ${String(error)}`;
        host.append(diagnostic);
    }
    return () => { for (const cleanup of cleanups)
        cleanup(); };
}
/** Standalone source stage without Phoenix. */
export function bootStandalone(root = document) {
    const host = root.querySelector('#semantic-stage');
    if (host && !host.dataset.liveManaged)
        mountStage(host);
}
