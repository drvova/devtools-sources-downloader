const path = require('path');
const CopyWebpackPlugin = require('copy-webpack-plugin');

module.exports = {
  entry: {
    devtools: './src/js/devtools.js',
    page: './src/js/page.js',
    injected: './src/js/injected.js',
    'stack-profile': './src/js/stack-profile.js',
    'framework-introspect': './src/js/framework-introspect.js'
  },
  output: {
    path: path.resolve(__dirname, 'dist/js'),
    filename: '[name].js'
  },
  plugins: [
    new CopyWebpackPlugin({
      patterns: [
        { from: 'manifest.json', to: path.resolve(__dirname, 'dist/manifest.json') },
        { from: 'src/html', to: path.resolve(__dirname, 'dist/html') },
        { from: 'src/css', to: path.resolve(__dirname, 'dist/css') },
        { from: 'src/images', to: path.resolve(__dirname, 'dist/images') }
      ]
    })
  ],
  resolve: {
    extensions: ['.js']
  }
};
