/*
Language: Solidity
Description: Solidity is a statically-typed programming language designed for developing smart contracts that run on Ethereum.
Author: Sam Pospischil <sam@changedsince.com>
Contributors: Yorick de Wid <yorick17@outlook.com>
Website: https://soliditylang.org
Category: web
*/

(function() {
  'use strict';

function solidity(hljs) {
  const SOL_KEYWORDS = {
    keyword:
      'pragma solidity contract library interface using import as at from is ' +
      'constructor function modifier event indexed anonymous struct enum mapping error ' +
      'if else while for do break continue return throw emit try catch ' +
      'assembly let switch case default leave ' +
      'public private internal external pure view payable constant ' +
      'memory storage calldata transient immutable override virtual abstract ' +
      'receive fallback returns require assert revert ' +
      'new delete this super selfdestruct ' +
      'type unchecked global',
    literal:
      'true false wei gwei ether seconds minutes hours days weeks years',
    built_in:
      'block blockhash gasleft msg tx now ' +
      'abi bytes string address bool int uint fixed ufixed ' +
      'bytes1 bytes2 bytes3 bytes4 bytes5 bytes6 bytes7 bytes8 bytes9 bytes10 bytes11 bytes12 bytes13 bytes14 bytes15 bytes16 bytes17 bytes18 bytes19 bytes20 bytes21 bytes22 bytes23 bytes24 bytes25 bytes26 bytes27 bytes28 bytes29 bytes30 bytes31 bytes32 ' +
      'int8 int16 int24 int32 int40 int48 int56 int64 int72 int80 int88 int96 int104 int112 int120 int128 int136 int144 int152 int160 int168 int176 int184 int192 int200 int208 int216 int224 int232 int240 int248 int256 ' +
      'uint8 uint16 uint24 uint32 uint40 uint48 uint56 uint64 uint72 uint80 uint88 uint96 uint104 uint112 uint120 uint128 uint136 uint144 uint152 uint160 uint168 uint176 uint184 uint192 uint200 uint208 uint216 uint224 uint232 uint240 uint248 uint256 ' +
      'fixed8x0 fixed8x1 fixed8x2 fixed8x3 fixed8x4 fixed8x5 fixed8x6 fixed8x7 fixed8x8 fixed8x9 fixed8x10 fixed8x11 fixed8x12 fixed8x13 fixed8x14 fixed8x15 fixed8x16 fixed8x17 fixed8x18 ' +
      'ufixed8x0 ufixed8x1 ufixed8x2 ufixed8x3 ufixed8x4 ufixed8x5 ufixed8x6 ufixed8x7 ufixed8x8 ufixed8x9 ufixed8x10 ufixed8x11 ufixed8x12 ufixed8x13 ufixed8x14 ufixed8x15 ufixed8x16 ufixed8x17 ufixed8x18 ' +
      'keccak256 sha256 sha3 ripemd160 ecrecover addmod mulmod ' +
      'prevrandao blobhash blobbasefee tload tstore mcopy clz'
  };

  const SOL_NUMBER = {
    className: 'number',
    variants: [
      { begin: '\\b(0[bB][01]+)' },
      { begin: '\\b(0[oO][0-7]+)' },
      { begin: hljs.C_NUMBER_RE }
    ],
    relevance: 0
  };

  const SOL_FUNC_PARAMS = {
    className: 'params',
    begin: /\(/,
    end: /\)/,
    excludeBegin: true,
    excludeEnd: true,
    keywords: SOL_KEYWORDS,
    contains: [
      hljs.C_LINE_COMMENT_MODE,
      hljs.C_BLOCK_COMMENT_MODE,
      hljs.APOS_STRING_MODE,
      hljs.QUOTE_STRING_MODE,
      SOL_NUMBER
    ]
  };

  const SOL_IDENT_RE = '[A-Za-z_$][A-Za-z0-9_$]*';

  const SOL_GUARDS = {
    className: 'operator',
    begin: /\b(require|assert|revert)\b/
  };

  const SOL_ASSEMBLY = {
    className: 'keyword',
    begin: /\bassembly\b/,
    end: /\{/,
    keywords: 'assembly',
    contains: [
      {
        className: 'string',
        begin: '"',
        end: '"',
        contains: [hljs.BACKSLASH_ESCAPE]
      }
    ]
  };

  return {
    name: 'Solidity',
    aliases: ['sol'],
    keywords: SOL_KEYWORDS,
    contains: [
      // Solidity version pragma
      {
        className: 'meta',
        begin: /pragma\s+solidity\s+[^;]+;/,
        keywords: 'pragma solidity'
      },
      
      // SPDX License
      {
        className: 'meta',
        begin: /\/\/\s*SPDX-License-Identifier:/
      },

      hljs.C_LINE_COMMENT_MODE,
      hljs.C_BLOCK_COMMENT_MODE,
      hljs.APOS_STRING_MODE,
      hljs.QUOTE_STRING_MODE,
      
      // Hex numbers
      {
        className: 'number',
        begin: '\\b0[xX][0-9a-fA-F]+[lL]?\\b',
        relevance: 0
      },
      
      SOL_NUMBER,
      
      // Address literals
      {
        className: 'number',
        begin: '\\b0x[0-9a-fA-F]{40}\\b'
      },
      
      // Function definitions
      {
        className: 'function',
        beginKeywords: 'function modifier event constructor fallback receive',
        end: /[{;]/,
        excludeEnd: true,
        keywords: SOL_KEYWORDS,
        contains: [
          {
            className: 'title',
            begin: SOL_IDENT_RE,
            relevance: 0
          },
          SOL_FUNC_PARAMS
        ]
      },
      
      // Contract/interface/library definitions
      {
        className: 'class',
        beginKeywords: 'contract interface library',
        end: /[{]/,
        excludeEnd: true,
        keywords: SOL_KEYWORDS,
        contains: [
          {
            className: 'title',
            begin: SOL_IDENT_RE
          },
          {
            begin: /is\s+/,
            keywords: 'is',
            contains: [
              {
                className: 'title',
                begin: SOL_IDENT_RE
              }
            ]
          }
        ]
      },
      
      // State variable declarations
      {
        begin: '\\b(mapping|struct|enum)\\b',
        keywords: 'mapping struct enum',
        contains: [
          {
            className: 'title',
            begin: SOL_IDENT_RE
          }
        ]
      },
      
      SOL_GUARDS,
      SOL_ASSEMBLY,
      
      // Import statements
      {
        className: 'meta',
        begin: /import\s+/,
        end: /;/,
        keywords: 'import from as',
        contains: [
          hljs.APOS_STRING_MODE,
          hljs.QUOTE_STRING_MODE
        ]
      },
      
      // Using statements
      {
        begin: /using\s+/,
        keywords: 'using for',
        contains: [
          {
            className: 'title',
            begin: SOL_IDENT_RE
          }
        ]
      }
    ],
    illegal: '\\#'
  };
}

// Register the language
if (typeof hljs !== 'undefined') {
  hljs.registerLanguage('solidity', solidity);
  hljs.registerLanguage('sol', solidity);
} else {
  // If hljs is not available yet, register on DOMContentLoaded
  document.addEventListener('DOMContentLoaded', function() {
    if (typeof hljs !== 'undefined') {
      hljs.registerLanguage('solidity', solidity);
      hljs.registerLanguage('sol', solidity);
    }
  });
}

// Make solidity function globally available
if (typeof window !== 'undefined') {
  window.solidity = solidity;
}

})(); 