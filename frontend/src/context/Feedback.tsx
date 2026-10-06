import { createContext, useCallback, useContext, useMemo, useRef, useState, type ReactNode } from 'react'
import { createPortal } from 'react-dom'
import { Dialog } from '@/components/Dialog'
import { Button } from '@/components/ui'

interface Toast {
  id: number
  message: string
  actionLabel?: string
  onAction?: () => void
}

interface ConfirmOpts {
  title: string
  message?: ReactNode
  confirmLabel?: string
  cancelLabel?: string
  danger?: boolean
}
interface PromptOpts {
  title: string
  label?: string
  initial?: string
  confirmLabel?: string
  multiline?: boolean
  placeholder?: string
}

interface FeedbackApi {
  toast: (message: string, opts?: { actionLabel?: string; onAction?: () => void; durationMs?: number }) => void
  confirm: (opts: ConfirmOpts) => Promise<boolean>
  prompt: (opts: PromptOpts) => Promise<string | null>
  alert: (title: string, message?: ReactNode) => Promise<void>
}

const Ctx = createContext<FeedbackApi | null>(null)

type DialogState =
  | { kind: 'confirm'; opts: ConfirmOpts; resolve: (v: boolean) => void }
  | { kind: 'prompt'; opts: PromptOpts; resolve: (v: string | null) => void }
  | { kind: 'alert'; title: string; message?: ReactNode; resolve: () => void }

export function FeedbackProvider({ children }: { children: ReactNode }) {
  const [toasts, setToasts] = useState<Toast[]>([])
  const [dialog, setDialog] = useState<DialogState | null>(null)
  const [promptValue, setPromptValue] = useState('')
  const idRef = useRef(0)

  const toast = useCallback<FeedbackApi['toast']>((message, opts) => {
    const id = ++idRef.current
    setToasts((t) => [...t.slice(-3), { id, message, actionLabel: opts?.actionLabel, onAction: opts?.onAction }])
    setTimeout(() => setToasts((t) => t.filter((x) => x.id !== id)), opts?.durationMs ?? 4000)
  }, [])

  const confirm = useCallback<FeedbackApi['confirm']>(
    (opts) => new Promise((resolve) => setDialog({ kind: 'confirm', opts, resolve })),
    [],
  )
  const prompt = useCallback<FeedbackApi['prompt']>(
    (opts) =>
      new Promise((resolve) => {
        setPromptValue(opts.initial ?? '')
        setDialog({ kind: 'prompt', opts, resolve })
      }),
    [],
  )
  const alertFn = useCallback<FeedbackApi['alert']>(
    (title, message) => new Promise((resolve) => setDialog({ kind: 'alert', title, message, resolve })),
    [],
  )

  const api = useMemo(() => ({ toast, confirm, prompt, alert: alertFn }), [toast, confirm, prompt, alertFn])

  const close = () => setDialog(null)

  return (
    <Ctx.Provider value={api}>
      {children}
      {createPortal(
        <div className="toast-host">
          {toasts.map((t) => (
            <div className="toast" key={t.id}>
              <span>{t.message}</span>
              {t.actionLabel && <button onClick={t.onAction}>{t.actionLabel}</button>}
            </div>
          ))}
        </div>,
        document.body,
      )}
      {dialog?.kind === 'confirm' && (
        <Dialog
          title={dialog.opts.title}
          onClose={() => {
            dialog.resolve(false)
            close()
          }}
          actions={
            <>
              <Button variant="text" onClick={() => { dialog.resolve(false); close() }}>
                {dialog.opts.cancelLabel ?? 'Cancel'}
              </Button>
              <Button variant={dialog.opts.danger ? 'danger' : 'solid'} onClick={() => { dialog.resolve(true); close() }}>
                {dialog.opts.confirmLabel ?? 'OK'}
              </Button>
            </>
          }
        >
          {dialog.opts.message}
        </Dialog>
      )}
      {dialog?.kind === 'prompt' && (
        <Dialog
          title={dialog.opts.title}
          onClose={() => {
            dialog.resolve(null)
            close()
          }}
          actions={
            <>
              <Button variant="text" onClick={() => { dialog.resolve(null); close() }}>Cancel</Button>
              <Button variant="solid" onClick={() => { dialog.resolve(promptValue); close() }}>
                {dialog.opts.confirmLabel ?? 'OK'}
              </Button>
            </>
          }
        >
          {dialog.opts.multiline ? (
            <textarea className="textarea" autoFocus value={promptValue} placeholder={dialog.opts.placeholder ?? dialog.opts.label} onChange={(e) => setPromptValue(e.target.value)} />
          ) : (
            <input
              className="input"
              autoFocus
              value={promptValue}
              placeholder={dialog.opts.placeholder ?? dialog.opts.label}
              onChange={(e) => setPromptValue(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === 'Enter') {
                  dialog.resolve(promptValue)
                  close()
                }
              }}
            />
          )}
        </Dialog>
      )}
      {dialog?.kind === 'alert' && (
        <Dialog
          title={dialog.title}
          onClose={() => {
            dialog.resolve()
            close()
          }}
          actions={<Button variant="solid" onClick={() => { dialog.resolve(); close() }}>OK</Button>}
        >
          {dialog.message}
        </Dialog>
      )}
    </Ctx.Provider>
  )
}

export function useFeedback(): FeedbackApi {
  const v = useContext(Ctx)
  if (!v) throw new Error('useFeedback must be used inside <FeedbackProvider>')
  return v
}
