import { NextRequest } from 'next/server';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

export async function GET(request: NextRequest) {
  const url = new URL('/api/browserless', request.url);
  request.nextUrl.searchParams.forEach((value, key) => url.searchParams.set(key, value));
  url.searchParams.set('action', 'capacity');
  return fetch(url, {
    headers: { 'cache-control': 'no-store' },
    cache: 'no-store',
  });
}
