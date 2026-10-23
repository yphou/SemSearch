export const init: (modelDir: string) => boolean;
export const initVisual: (modelDir: string) => boolean;
export const embed: (text: string) => Float32Array;
export const embedDoc: (title: string, text: string) => Float32Array;
export const imgEmbed: (imagePath: string) => Float32Array;
export const isLoaded: () => boolean;
export const prepareDir: (path: string) => boolean;
