"""
ERC721 that gives the user an on-chain credit card
- standard ERC721 functions
- calls issuer to open a new account on mint


Example svg for metadata:
<svg height="215" width="340" viewBox="0 0 340 215" xmlns="http://www.w3.org/2000/svg">
	<style>
    	.heavy{
        	fill: white;
            font: bold 30px sans-serif;
        }
        .light{
        	fill: white;
            font: 14px sans-serif;
        }
    </style>
	<g>
  	<rect x="0" y="0" rx="20" ry="20" width="340" height="215" style="fill:black;/"></rect>
  	<text x="25" y="115" class="heavy">ID #1</text>
    <text x="25" y="140" class="light">Level: 1
    <tspan x="25" dy="20">Status: BORROWING</tspan>
    <tspan x="25" dy="20">Outstanding debt: 100 CUSD</tspan>
    </text>
    </g>
    
</svg>
"""

