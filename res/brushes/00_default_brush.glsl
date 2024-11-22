#version 330 core

in vec2 uv;
out vec4 fragment;

uniform sampler2D distance_field;
uniform float width = 0.02;
uniform vec3 color = vec3(1.0, 0.0, 0.0);
uniform float alpha_falloff_multiplier = 5;

void main()
{
    float distance = texture(distance_field, vec2(uv.x, uv.y)).r;
    float alpha = 1.0 - clamp((distance - width) * alpha_falloff_multiplier * 10, 0.0, 1.0);
    if (alpha <= 0.0) {
        discard;
    }
    fragment = vec4(color, alpha);
}
