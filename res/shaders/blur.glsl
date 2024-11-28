#version 330

in vec2 uv;
out vec4 fragment;
uniform sampler2D input_image;
uniform float sample_dist = 0.01;

void main()
{
    vec4 tmp = texture(input_image, vec2(uv.x, uv.y));
    for (int i = -1; i <= 1; ++i) {
        for (int j = -1; j <= 1; ++j) {
           tmp += texture(input_image, vec2(uv.x + sample_dist / 100.0 * i, uv.y + sample_dist / 100.0 * j));
        }
    }
    fragment = tmp / 9;
}
