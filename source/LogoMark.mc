using Toybox.Lang;

//! GENERADO por tools/gen_logo.py — no editar a mano.
//! Marca de OpenAI (blossom 2025) en una rejilla 0..200 con centro 100,100,
//! partida en los trozos de un sexto del símbolo: el reloj los dibuja seis
//! veces, girados 60°. SVG de Wikimedia Commons (dominio público); app
//! personal no oficial.
(:glance)
module LogoMark {
    const SIZE = 200;
    const STEP = 6;                     //!< puntos por tramo del abanico
    const NP = 2;                       //!< trozos por sexto
    const N = [29, 14];   //!< puntos de cada trozo
    const CX = [188, 129];  //!< centro del abanico (x)
    const CY = [100, 85];  //!< centro del abanico (y)
    const PTS = [
        183, 52, 172, 59, 172, 66, 165, 62, 152, 70, 169, 80,
        174, 83, 180, 89, 184, 96, 185, 101, 187, 108, 187, 116,
        185, 123, 182, 130, 180, 133, 172, 142, 184, 148, 191, 140,
        196, 131, 199, 121, 200, 115, 200, 108, 199, 101, 196, 93,
        191, 83, 184, 75, 185, 66, 185, 58, 184, 52,
        135, 80, 122, 87, 122, 113, 135, 120, 135, 95, 138, 96,
        150, 103, 152, 105, 152, 130, 165, 138, 165, 100, 164, 98,
        162, 95, 137, 80
    ];
}
