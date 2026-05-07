import { NextRequest } from 'next/server';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

export async function POST(request: NextRequest) {
  const url = new URL('/api/browserless', request.url);
  request.nextUrl.searchParams.forEach((value, key) => url.searchParams.set(key, value));
  url.searchParams.set('action', 'function');
  return fetch(url, {
    method: 'POST',
    headers: {
      'content-type': request.headers.get('content-type') || 'application/json',
      'cache-control': 'no-store',
    },
    body: await request.text(),
    cache: 'no-store',
  });
}
