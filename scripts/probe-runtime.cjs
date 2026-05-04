const token = process.env.BROWSERLESS_TOKEN || process.env.TOKEN || 'change-me';
const port = process.env.PORT || '3000';
const url = `http://localhost:${port}/pressure?token=${encodeURIComponent(token)}`;

fetch(url)
  .then(async response => {
    const text = await response.text();
    if (!response.ok) throw new Error(`HTTP ${response.status}: ${text}`);
    console.log(text);
  })
  .catch(error => {
    console.error(error instanceof Error ? error.message : String(error));
    process.exit(1);
  });
