import { createClient } from '../server/elastic/client.mjs';
import { DEFAULT_INFERENCE_ID, mappings } from '../server/elastic/schema.mjs';
import { setup } from '../server/elastic/store.mjs';

const command = process.argv[2];
const inferenceId = process.env.ELASTICSEARCH_INFERENCE_ID || DEFAULT_INFERENCE_ID;
try {
  if (command === 'console') {
    for (const [name, body] of Object.entries(mappings(inferenceId))) {
      console.log(`PUT /${name}\n${JSON.stringify(body, null, 2)}\n`);
    }
  } else if (command === 'setup') {
    console.log(JSON.stringify(await setup(createClient(), inferenceId), null, 2));
  } else if (command === 'status') {
    const request = createClient();
    console.log(JSON.stringify(await request('GET', '/_inference/_all'), null, 2));
    for (const name of Object.keys(mappings(inferenceId))) {
      const result = await request('GET', `/${name}/_count`);
      console.log(`${name}: ${result.count} documents`);
    }
  } else {
    throw new Error('Usage: node --env-file-if-exists=.env scripts/elastic.mjs <setup|status|console>');
  }
} catch (error) {
  console.error(error.message);
  process.exitCode = 1;
}
