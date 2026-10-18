import type { ApiClient } from "./contracts";

// AuthGate replaces the initial standalone/demo scope before mounting private UI.
let generation = 0;
let owner: string | null = "standalone";

export class AuthGenerationExpired extends Error {
  constructor() { super("登录状态已改变，请重新打开学习页面。"); this.name = "AuthGenerationExpired"; }
}

export function captureAuthGeneration(): number { return generation; }
export function currentAuthOwner(): string | null { return owner; }
export function isAuthGenerationCurrent(expected: number): boolean { return owner !== null && generation === expected; }
export function assertAuthGeneration(expected: number): void {
  if (!isAuthGenerationCurrent(expected)) throw new AuthGenerationExpired();
}
export function activateAuthGeneration(nextOwner: string): void {
  if (owner !== nextOwner) { generation++; owner = nextOwner; }
}
export function invalidateAuthGeneration(): void { generation++; owner = null; }

/** A stale component cannot start another RPC under a later login. */
export function scopeApiClient(client: ApiClient, expected: number): ApiClient {
  return new Proxy(client, {
    get(target, property, receiver) {
      const member: unknown = Reflect.get(target, property, receiver);
      if (typeof member !== "function") return member;
      return async (...args: unknown[]) => {
        assertAuthGeneration(expected);
        const result: unknown = await Reflect.apply(member, target, args);
        assertAuthGeneration(expected);
        return result;
      };
    },
  });
}
