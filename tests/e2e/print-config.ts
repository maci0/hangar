/** Loads playwright.config.ts under the caller's environment, prints the daemon settings as JSON, then removes the scratch HOME it made. */
import config from '../../playwright.config';

const [webServer] = [config.webServer].flat();
if (webServer === undefined) {
    throw new Error('playwright.config.ts must define a webServer');
}
const env = { ...Bun.env, ...webServer.env };
try {
    await Bun.write(Bun.stdout, JSON.stringify({
        home: env.HOME,
        configHomeIsHome: env.HANGAR_CONFIG_HOME === env.HOME,
        key: env.KV_API_KEY,
        port: env.KV_PORT,
        url: webServer.url,
    }));
} finally {
    await Bun.$`rm -rf ${env.HOME ?? ''}`;
}
