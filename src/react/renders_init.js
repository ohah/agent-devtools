(() => {
  const hook = window.__REACT_DEVTOOLS_GLOBAL_HOOK__;
  if (!hook || window.__AB_RENDERS_ACTIVE__) return;

  const MAX_COMPONENTS = 200;
  const data = {};
  const fps = { frames: [], last: 0, rafId: 0 };

  window.__AB_RENDERS__ = data;
  window.__AB_RENDERS_FPS__ = fps;
  window.__AB_RENDERS_START__ = performance.now();
  window.__AB_RENDERS_ACTIVE__ = true;

  function fpsLoop(now) {
    if (fps.last > 0) fps.frames.push(now - fps.last);
    fps.last = now;
    fps.rafId = requestAnimationFrame(fpsLoop);
  }
  fps.rafId = requestAnimationFrame(fpsLoop);

  const origOnCommit = hook.onCommitFiberRoot;
  window.__AB_RENDERS_ORIG_COMMIT__ = origOnCommit;

  hook.onCommitFiberRoot = function (rendererID, root) {
    try { walkFiber(root.current); } catch {}
    if (typeof origOnCommit === "function") {
      return origOnCommit.apply(hook, arguments);
    }
  };

  function getName(fiber) {
    if (!fiber.type || typeof fiber.type === "string") return null;
    return fiber.type.displayName || fiber.type.name || null;
  }

  function brief(val) {
    if (val === undefined) return "undefined";
    if (val === null) return "null";
    if (typeof val === "function") return "fn()";
    if (typeof val === "string") return val.length > 60 ? '"' + val.slice(0, 57) + '..."' : '"' + val + '"';
    if (typeof val === "number" || typeof val === "boolean") return String(val);
    if (Array.isArray(val)) return "Array(" + val.length + ")";
    if (typeof val === "object") {
      try {
        const keys = Object.keys(val);
        return keys.length <= 3 ? "{" + keys.join(", ") + "}" : "{" + keys.slice(0, 3).join(", ") + ", ...}";
      } catch { return "{...}"; }
    }
    return String(val).slice(0, 40);
  }

  function getChanges(fiber) {
    const changes = [];
    const alt = fiber.alternate;
    if (!alt) { changes.push({ type: "mount" }); return changes; }
    if (fiber.memoizedProps !== alt.memoizedProps) {
      const curr = fiber.memoizedProps || {};
      const prev = alt.memoizedProps || {};
      const allKeys = new Set([...Object.keys(curr), ...Object.keys(prev)]);
      for (const k of allKeys) {
        if (k !== "children" && curr[k] !== prev[k]) {
          changes.push({ type: "props", name: k, prev: brief(prev[k]), next: brief(curr[k]) });
        }
      }
    }
    if (fiber.memoizedState !== alt.memoizedState) {
      let curr = fiber.memoizedState;
      let prev = alt.memoizedState;
      let hookIdx = 0;
      while (curr || prev) {
        if ((curr && curr.memoizedState) !== (prev && prev.memoizedState)) {
          changes.push({
            type: "state",
            name: "hook #" + hookIdx,
            prev: brief(prev && prev.memoizedState),
            next: brief(curr && curr.memoizedState),
          });
        }
        curr = curr && curr.next;
        prev = prev && prev.next;
        hookIdx++;
      }
    }
    if (fiber.dependencies && fiber.dependencies.firstContext) {
      let ctx = fiber.dependencies.firstContext;
      let altCtx = alt.dependencies && alt.dependencies.firstContext;
      while (ctx) {
        if (!altCtx || ctx.memoizedValue !== (altCtx && altCtx.memoizedValue)) {
          const ctxName =
            (ctx.context && ctx.context.displayName) ||
            (ctx.context && ctx.context.Provider && ctx.context.Provider.displayName) ||
            "unknown";
          changes.push({
            type: "context",
            name: ctxName,
            prev: brief(altCtx && altCtx.memoizedValue),
            next: brief(ctx.memoizedValue),
          });
        }
        ctx = ctx.next;
        altCtx = altCtx && altCtx.next;
      }
    }
    if (changes.length === 0) {
      let parent = fiber.return;
      while (parent) {
        const pName = getName(parent);
        if (pName) {
          const suffix = !parent.alternate ? " (mount)" : "";
          changes.push({ type: "parent", name: pName + suffix });
          break;
        }
        parent = parent.return;
      }
      if (changes.length === 0) changes.push({ type: "parent", name: "unknown" });
    }
    return changes;
  }

  function childrenTime(fiber) {
    let t = 0;
    let child = fiber.child;
    while (child) {
      if (typeof child.actualDuration === "number") t += child.actualDuration;
      child = child.sibling;
    }
    return t;
  }

  function hasDomMutation(fiber) {
    if (!fiber.alternate) return true;
    let child = fiber.child;
    while (child) {
      if (typeof child.type === "string" && (child.flags & 6) > 0) return true;
      child = child.sibling;
    }
    return false;
  }

  function walkFiber(fiber) {
    if (!fiber) return;
    const tag = fiber.tag;
    if (tag === 0 || tag === 1 || tag === 2 || tag === 11 || tag === 15) {
      const didRender =
        fiber.alternate === null ||
        fiber.flags > 0 ||
        fiber.memoizedProps !== (fiber.alternate && fiber.alternate.memoizedProps) ||
        fiber.memoizedState !== (fiber.alternate && fiber.alternate.memoizedState);
      if (didRender) {
        const name = getName(fiber);
        if (name) {
          if (!(name in data) && Object.keys(data).length >= MAX_COMPONENTS) {
            // at cap - skip
          } else {
            if (!data[name]) {
              data[name] = {
                count: 0, mounts: 0, totalTime: 0, selfTime: 0,
                domMutations: 0, changes: [], _instances: new Set(),
              };
            }
            data[name].count++;
            if (!fiber.alternate) data[name].mounts++;
            if (!data[name]._instances.has(fiber)) {
              data[name]._instances.add(fiber);
              if (fiber.alternate) data[name]._instances.add(fiber.alternate);
            }
            if (typeof fiber.actualDuration === "number") {
              data[name].totalTime += fiber.actualDuration;
              data[name].selfTime += Math.max(0, fiber.actualDuration - childrenTime(fiber));
            }
            if (hasDomMutation(fiber)) data[name].domMutations++;
            const ch = getChanges(fiber);
            for (const c of ch) {
              if (data[name].changes.length < 50) data[name].changes.push(c);
            }
          }
        }
      }
    }
    walkFiber(fiber.child);
    walkFiber(fiber.sibling);
  }
})()
