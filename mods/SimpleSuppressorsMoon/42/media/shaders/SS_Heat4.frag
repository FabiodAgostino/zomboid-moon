#version 330
in vec3 vertColour;
in vec3 vertNormal;
in vec2 texCoords;
// Zomboid maps this exact output name to gl_FragColor on OpenGL 2.1.
out vec4 colour;
uniform sampler2D Texture;
uniform float Alpha;
uniform vec3 TintColour;
uniform vec3 AmbientColour;
uniform vec3 Light0Direction;
uniform vec3 Light0Colour;
uniform vec3 Light1Direction;
uniform vec3 Light1Colour;
uniform vec3 Light2Direction;
uniform vec3 Light2Colour;
uniform vec3 Light3Direction;
uniform vec3 Light3Colour;
uniform vec3 Light4Direction;
uniform vec3 Light4Colour;

vec3 light(vec3 direction, vec3 colour, vec3 normal) {
    return colour * max(dot(normal, direction / max(length(direction), 0.0001)), 0.0);
}
#if __VERSION__ >= 130
#define sampleTexture texture
#else
#define sampleTexture texture2D
#endif

void main() {
    vec4 material = sampleTexture(Texture, texCoords);
    if (material.a < 0.01) discard;
    vec3 normal = normalize(vertNormal);
    vec3 lighting = AmbientColour
        + light(Light0Direction, Light0Colour, normal)
        + light(Light1Direction, Light1Colour, normal)
        + light(Light2Direction, Light2Colour, normal)
        + light(Light3Direction, Light3Colour, normal)
        + light(Light4Direction, Light4Colour, normal);
    vec3 litMetal = material.rgb * TintColour * min(lighting, vec3(1.0));
    // Emission is shaded on the existing mesh, with its ordinary depth test.
    // Keep texture variation and a broad temperature gradient; no halo sprite.
    float heat = 0.666667;
    float gradient = 0.65 + 0.35 * sin(clamp(texCoords.y, 0.0, 1.0) * 3.14159265);
    float detail = 0.45 + 0.55 * clamp(dot(material.rgb, vec3(0.3333)) * 4.0, 0.0, 1.0);
    vec3 hotMetal = mix(vec3(0.55, 0.005, 0.001), vec3(1.0, 0.16, 0.008), heat * heat);
    vec3 emission = hotMetal * (0.22 * gradient * detail);
    colour = vec4(Alpha * (litMetal + emission) * vertColour, Alpha * material.a);
}
