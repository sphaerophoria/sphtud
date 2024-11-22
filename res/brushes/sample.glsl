#version 330

in vec2 uv;
out vec4 fragment;

uniform sampler2D distance_field;
uniform sampler2D input_image;
uniform vec2 sample_offs = vec2(0.3, 0.3);
uniform float width = 0.02;

void main()
{
    float distance = texture(distance_field, uv).r;
    if (distance >= width) discard;

    fragment = texture(input_image, uv + sample_offs);
}
