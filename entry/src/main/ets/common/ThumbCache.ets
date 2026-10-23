// SemSearch (Phase 14): process-wide thumbnail cache for the Smart Album grids.
// The photo-library grid can hold 1600+ records; each cell decodes its 144px
// thumbnail through this cache so scrolling re-uses pixels instead of hitting
// PhotoAsset.getThumbnail / ImageSource repeatedly.
// - inflight de-dup: concurrent requests for the same id join one load
// - capacity eviction: FIFO evict of the oldest entry beyond MAX_ENTRIES
// - loader injection: the page registers how to load an id (media asset vs
//   sandbox file); the cache itself stays UI-free and unit-testable.
import { image } from '@kit.ImageKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

type ThumbLoader = (id: string) => Promise<image.PixelMap | null>;
type ThumbCallback = (pm: image.PixelMap | null) => void;

const MAX_ENTRIES: number = 480;
const TAG: string = 'SemSearch';

export class ThumbCacheImpl {
  private cache: Map<string, image.PixelMap> = new Map();
  private inflight: Map<string, Promise<image.PixelMap | null>> = new Map();
  private loader: ThumbLoader | null = null;

  setLoader(loader: ThumbLoader): void {
    this.loader = loader;
  }

  // Test/hot-reload hook: drop cached pixels (does not cancel loads).
  clear(): void {
    this.cache.clear();
    this.inflight.clear();
  }

  drop(id: string): void {
    this.cache.delete(id);
  }

  peek(id: string): image.PixelMap | null {
    const hit: image.PixelMap | undefined = this.cache.get(id);
    return hit !== undefined ? hit : null;
  }

  async get(id: string): Promise<image.PixelMap | null> {
    const hit: image.PixelMap | undefined = this.cache.get(id);
    if (hit !== undefined) {
      // refresh FIFO position so recently shown cells survive eviction
      this.cache.delete(id);
      this.cache.set(id, hit);
      return hit;
    }
    const pending: Promise<image.PixelMap | null> | undefined = this.inflight.get(id);
    if (pending !== undefined) {
      return pending;
    }
    if (this.loader === null) {
      return null;
    }
    const load: ThumbLoader = this.loader;
    const task: Promise<image.PixelMap | null> = load(id)
      .then((pm: image.PixelMap | null): image.PixelMap | null => {
        if (pm !== null) {
          this.cache.set(id, pm);
          while (this.cache.size > MAX_ENTRIES) {
            // Map iterates in insertion order: drop the oldest entry
            let oldestKey: string | null = null;
            for (const key of this.cache.keys()) {
              oldestKey = key;
              break;
            }
            if (oldestKey === null) {
              break;
            }
            this.cache.delete(oldestKey);
          }
        }
        this.inflight.delete(id);
        return pm;
      })
      .catch((e: Object): image.PixelMap | null => {
        hilog.error(0x0000, TAG, 'thumb load failed for %{public}s: %{public}s', id, `${e}`);
        this.inflight.delete(id);
        return null;
      });
    this.inflight.set(id, task);
    return task;
  }
}

export const thumbCache: ThumbCacheImpl = new ThumbCacheImpl();
