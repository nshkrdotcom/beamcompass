/** Phoenix JS lifecycle is an enhancement; server/static navigation remains usable. */
import { Socket } from 'phoenix';
import { LiveSocket } from 'phoenix_live_view';
import { mountStage } from '../ts/stage';

type Hook = { el: HTMLElement; cleanup?: () => void };
const Hooks = {
  SemanticStage: {
    mounted(this: Hook) { this.el.dataset.liveManaged = 'true'; this.cleanup = mountStage(this.el); },
    updated(this: Hook) { this.cleanup?.(); this.cleanup = mountStage(this.el); },
    destroyed(this: Hook) { this.cleanup?.(); }
  }
};
const csrfToken = document.querySelector<HTMLMetaElement>('meta[name="csrf-token"]')?.content;
if (csrfToken) {
  const liveSocket = new LiveSocket('/live', Socket, {
    params: { _csrf_token: csrfToken }, hooks: Hooks
  });
  liveSocket.connect();
}
