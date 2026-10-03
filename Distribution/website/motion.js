// Enhance visible content only: the page remains readable without JavaScript.
if ('IntersectionObserver' in window && !matchMedia('(prefers-reduced-motion: reduce)').matches) {
  const observer = new IntersectionObserver((entries) => {
    for (const entry of entries) {
      if (!entry.isIntersecting) continue;
      entry.target.classList.add('motion-arrived');
      observer.unobserve(entry.target);
    }
  }, { threshold: 0.15 });

  document.querySelectorAll('.section-intro, .feature-story .app-window, .feature-copy')
    .forEach((element) => observer.observe(element));
}
