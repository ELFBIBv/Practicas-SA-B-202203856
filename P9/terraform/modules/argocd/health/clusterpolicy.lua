-- Backport del health de ArgoCD v3.6 (no existe en v3.5.3, la version instalada).
-- Sin este Lua, kyverno.io/ClusterPolicy queda Healthy en cuanto se crea, antes
-- de que Kyverno la cargue y configure el webhook: los Pods de la ola 0 se
-- admitirian sin validar.
-- Fuente: P9/docs/diseno-sync-waves.md §3.3.
local hs = { status = "Progressing", message = "Esperando que Kyverno cargue la politica" }
if obj.status ~= nil and obj.status.conditions ~= nil then
  for _, c in ipairs(obj.status.conditions) do
    if c.type == "Ready" then
      if c.status == "True" then
        hs.status = "Healthy"
      else
        hs.status = "Degraded"
      end
      hs.message = c.message or ""
      return hs
    end
  end
end
return hs
