const clock = document.getElementById('clock');
function updateClock() { clock.textContent = new Date().toLocaleTimeString(); }
updateClock();
setInterval(updateClock, 1000);
