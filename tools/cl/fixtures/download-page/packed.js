// Dean Edwards' packer, verbatim and minified: `detect_packer` keys on
// "function(p,a,c,k,e," with no spaces, so this has to be the real shape rather
// than a readable reformatting. It unpacks to `console.log("packed ok");`.
eval(function(p,a,c,k,e,d){e=function(c){return c.toString(a)};if(!''.replace(/^/,String)){while(c--)d[e(c)]=k[c]||e(c);k=[function(e){return d[e]}];e=function(){return'\\w+'};c=1};while(c--)if(k[c])p=p.replace(new RegExp('\\b'+e(c)+'\\b','g'),k[c]);return p}('0.1("2 3");',62,4,'console|log|packed|ok'.split('|'),0,{}))
