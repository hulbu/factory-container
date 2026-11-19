// A static file server for the entrypoint's tests: serves folder $2 on 127.0.0.1, writes its port to file $3.
import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { writeFileSync } from 'node:fs';
import { join, normalize } from 'node:path';

const [folder, portFile] = process.argv.slice(2);
const server = createServer(async (request, response) => {
  const path = normalize(decodeURIComponent(new URL(request.url, 'http://x').pathname));
  try {
    const body = await readFile(join(folder, path));
    response.writeHead(200, { 'content-length': body.length });
    response.end(body);
  } catch {
    response.writeHead(404);
    response.end();
  }
});
server.listen(0, '127.0.0.1', () => writeFileSync(portFile, String(server.address().port)));
